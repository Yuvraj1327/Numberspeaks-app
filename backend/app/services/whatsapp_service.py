"""
Sends each user's calculated bonus to their WhatsApp number and records
the outcome. Kept deliberately separate from bonus calculation
(app/services/bonus_service.py, bonus_calculator.py): this module never
computes or changes a bonus amount, it only reads an already-calculated
bonus_results row and reports on it. It also owns its own small slice of
Supabase access (the whatsapp_messages table) rather than growing
reports_service.py, so the whole WhatsApp feature stays removable on its
own.

Idempotency: by default, a bonus_results row that already has a
successful ('sent') message is skipped, so re-running this for a report
never spams a user who was already notified. Pass force=True to
deliberately resend anyway (e.g. an operator explicitly asked to).
"""

import logging
from datetime import datetime, timezone
from typing import List, Optional

from supabase import Client

from app.schemas.whatsapp import WhatsAppMessageResult, WhatsAppSendSummary
from app.services.reports_service import get_bonus_results_for_report, to_bonus_result
from app.services.whatsapp_client import WhatsAppNotConfiguredError, send_whatsapp_message
from app.services.whatsapp_templates import build_bonus_message

logger = logging.getLogger("numberspeaks")


def _get_latest_sent_message(db: Client, bonus_result_id: str) -> Optional[dict]:
    res = (
        db.table("whatsapp_messages")
        .select("id, status, sent_at")
        .eq("bonus_result_id", bonus_result_id)
        .eq("status", "sent")
        .order("created_at", desc=True)
        .limit(1)
        .execute()
    )
    return res.data[0] if res.data else None


def _record_message(
    db: Client,
    bonus_result_id: str,
    whatsapp_number: str,
    message_body: str,
    status: str,
    provider_message_id: Optional[str] = None,
    error_message: Optional[str] = None,
) -> None:
    payload = {
        "bonus_result_id": bonus_result_id,
        "whatsapp_number": whatsapp_number,
        "message_body": message_body,
        "status": status,
        "provider_message_id": provider_message_id,
        "error_message": error_message,
    }
    if status == "sent":
        payload["sent_at"] = datetime.now(timezone.utc).isoformat()

    db.table("whatsapp_messages").insert(payload).execute()


def send_bonus_whatsapp_for_report(db: Client, report_id: str, force: bool = False) -> WhatsAppSendSummary:
    rows = get_bonus_results_for_report(db, report_id)
    eligible_rows = [row for row in rows if row.get("bonus_amount") is not None]

    results: List[WhatsAppMessageResult] = []
    sent_count = 0
    failed_count = 0
    skipped_count = 0

    for row in eligible_rows:
        user = row.get("users") or {}
        user_id = row.get("user_id") or user.get("id") or ""
        user_name = user.get("name") or ""
        whatsapp_number = user.get("whatsapp_number")
        bonus_result_id = row["id"]
        bonus_amount = row.get("bonus_amount") or 0

        if bonus_amount <= 0:
            skipped_count += 1
            results.append(
                WhatsAppMessageResult(
                    bonus_result_id=bonus_result_id,
                    user_id=user_id,
                    user_name=user_name,
                    whatsapp_number=whatsapp_number,
                    status="skipped_no_bonus",
                    error="No bonus is owed for this user (profit/loss was not a loss).",
                )
            )
            continue

        if not whatsapp_number:
            skipped_count += 1
            results.append(
                WhatsAppMessageResult(
                    bonus_result_id=bonus_result_id,
                    user_id=user_id,
                    user_name=user_name,
                    whatsapp_number=None,
                    status="skipped_no_number",
                    error="This user has no WhatsApp number on file.",
                )
            )
            continue

        if not force:
            already_sent = _get_latest_sent_message(db, bonus_result_id)
            if already_sent:
                skipped_count += 1
                results.append(
                    WhatsAppMessageResult(
                        bonus_result_id=bonus_result_id,
                        user_id=user_id,
                        user_name=user_name,
                        whatsapp_number=whatsapp_number,
                        status="skipped_already_sent",
                        error=f"Already sent at {already_sent.get('sent_at')}. Use force=true to resend.",
                    )
                )
                continue

        message = build_bonus_message(to_bonus_result(row))

        try:
            send_result = send_whatsapp_message(whatsapp_number, message)
        except WhatsAppNotConfiguredError:
            raise  # system-configuration issue — let the endpoint turn this into a clean 503

        if send_result.success:
            sent_count += 1
            _record_message(
                db, bonus_result_id, whatsapp_number, message,
                status="sent", provider_message_id=send_result.provider_message_id,
            )
            results.append(
                WhatsAppMessageResult(
                    bonus_result_id=bonus_result_id,
                    user_id=user_id,
                    user_name=user_name,
                    whatsapp_number=whatsapp_number,
                    status="sent",
                    message=message,
                    provider_message_id=send_result.provider_message_id,
                )
            )
        else:
            failed_count += 1
            try:
                _record_message(
                    db, bonus_result_id, whatsapp_number, message,
                    status="failed", error_message=send_result.error,
                )
            except Exception as exc:  # noqa: BLE001
                logger.warning("Could not record failed WhatsApp attempt for %s: %s", bonus_result_id, exc)
            results.append(
                WhatsAppMessageResult(
                    bonus_result_id=bonus_result_id,
                    user_id=user_id,
                    user_name=user_name,
                    whatsapp_number=whatsapp_number,
                    status="failed",
                    message=message,
                    error=send_result.error,
                )
            )

    return WhatsAppSendSummary(
        report_id=report_id,
        total_eligible=len(eligible_rows),
        sent_count=sent_count,
        failed_count=failed_count,
        skipped_count=skipped_count,
        results=results,
    )
