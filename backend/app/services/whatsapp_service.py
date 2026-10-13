"""
Sends bonus messages through the No1API integration — one at a time or as a
rate-limited background bulk run.

Safety rules (each protects against a duplicate or a false status):
  1. Ownership + eligibility (own report, calculated, payable > 0, valid saved number).
  2. 503 if the provider isn't usable — BEFORE any record exists.
  3. Insert a 'sending' attempt first. A partial unique index in Postgres allows
     only one 'sending'/'sent' attempt per result, so a double click, a second
     tab, a bulk run overlapping a manual send, or a retry race gets refused and
     never reaches the provider.
  4. Only a provider-confirmed acceptance becomes 'sent'. A rejection is 'failed'.
     An unanswered request is 'unknown'. A failed/unknown message is only re-sent
     when the admin explicitly sends it again.
  5. Bulk runs need an explicit confirmation, a prior successful test message,
     and pause between messages.

An attempt left 'sending' (server died mid-call) is turned into 'unknown' after
STALE_SENDING_SECONDS so it never blocks the admin forever.
"""

import logging
import time
from datetime import datetime, timedelta, timezone
from typing import Dict, List, Optional, Tuple
from uuid import uuid4

from fastapi import HTTPException, status
from supabase import Client

from app.core.config import get_settings
from app.schemas.whatsapp import (
    BulkItemStatus,
    BulkSkipped,
    WhatsAppBulkProgress,
    WhatsAppBulkRequest,
    WhatsAppSendRequest,
    WhatsAppSendResponse,
    WhatsAppTestRequest,
    WhatsAppTestResponse,
    WhatsAppTestStatus,
)
from app.services import no1api_client
from app.services.no1api_client import ProviderNotConfigured, ProviderOutcomeUnknown, ProviderSendError
from app.services.reports_service import (
    chunked,
    get_bonus_result_by_id,
    get_bonus_results_for_report,
    is_unique_violation,
    safe_error,
)
from app.services.users_service import normalize_whatsapp_number

logger = logging.getLogger("numberspeaks")

STALE_SENDING_SECONDS = 600
UNKNOWN_OUTCOME = "Sending was interrupted and the outcome is unknown. Check WhatsApp before retrying."
_sleep = time.sleep  # replaced in tests


def _now() -> datetime:
    return datetime.now(timezone.utc)


def _parse(ts: Optional[str]) -> Optional[datetime]:
    try:
        return datetime.fromisoformat(str(ts).replace("Z", "+00:00")) if ts else None
    except ValueError:
        return None


def _require_provider() -> None:
    if not no1api_client.is_available():
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="WhatsApp sending is not configured on the server yet. Nothing was sent.",
        )


def _save_status(
    db: Client, owner_id: str, bonus_result_id: str, send_status: str, error: Optional[str], sent_at: Optional[str]
) -> None:
    db.table("bonus_results").update(
        {"whatsapp_send_status": send_status, "whatsapp_send_error": error, "whatsapp_sent_at": sent_at}
    ).eq("owner_id", owner_id).eq("id", bonus_result_id).execute()


def _expire_stale_sending(db: Client, owner_id: str, bonus_result_id: str) -> None:
    rows = (
        db.table("whatsapp_sends")
        .select("id, created_at")
        .eq("owner_id", owner_id)
        .eq("bonus_result_id", bonus_result_id)
        .eq("status", "sending")
        .execute()
        .data
        or []
    )
    for row in rows:
        created = _parse(row.get("created_at"))
        if created and _now() - created > timedelta(seconds=STALE_SENDING_SECONDS):
            db.table("whatsapp_sends").update(
                {"status": "unknown", "error_message": UNKNOWN_OUTCOME, "updated_at": _now().isoformat()}
            ).eq("id", row["id"]).execute()
            _save_status(db, owner_id, bonus_result_id, "unknown", UNKNOWN_OUTCOME, None)


def _eligibility(row: dict) -> Tuple[Optional[str], Optional[str]]:
    """(normalized number, None) if this result can be messaged, else (None, reason)."""
    payable = row.get("payable_bonus")
    if row.get("calculation_status") != "calculated" or payable is None or float(payable) <= 0:
        return None, "No payable bonus, so there is no bonus message to send."
    raw = ((row.get("users") or {}).get("whatsapp_number") or "").strip()
    if not raw:
        return None, "No WhatsApp number saved."
    try:
        number = normalize_whatsapp_number(raw)
    except HTTPException:
        return None, "The saved WhatsApp number is not valid."
    if not number:
        return None, "No WhatsApp number saved."
    return number, None


def _attempt(
    db: Client,
    owner_id: str,
    report_id: str,
    row: dict,
    message: str,
    batch_id: Optional[str] = None,
    acknowledge_unknown: bool = False,
) -> WhatsAppSendResponse:
    """Validate, record a 'sending' attempt, call the provider, record the outcome.
    Raises HTTPException for anything refused BEFORE the provider was contacted."""
    bonus_result_id = row["id"]
    number, reason = _eligibility(row)
    if number is None:
        code = status.HTTP_422_UNPROCESSABLE_ENTITY if "number" in (reason or "") else status.HTTP_409_CONFLICT
        raise HTTPException(status_code=code, detail=reason if code == 409 else f"{reason} Save a valid WhatsApp number first.")
    message = message.strip()
    if not message:
        raise HTTPException(status_code=status.HTTP_422_UNPROCESSABLE_ENTITY, detail="The message cannot be empty.")

    _expire_stale_sending(db, owner_id, bonus_result_id)
    # A re-send after an 'unknown' outcome could be a duplicate (the first message may
    # already have been delivered), so it needs the admin's explicit acknowledgement.
    last = (
        db.table("bonus_results").select("whatsapp_send_status").eq("owner_id", owner_id).eq("id", bonus_result_id)
        .limit(1).execute().data
    )
    if last and last[0].get("whatsapp_send_status") == "unknown" and not acknowledge_unknown:
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail="The previous attempt's outcome is unknown, so this message may already have been delivered. "
            "Check WhatsApp, then confirm that you want to send it again.",
        )
    try:
        inserted = (
            db.table("whatsapp_sends")
            .insert(
                {
                    "owner_id": owner_id,
                    "report_id": report_id,
                    "user_id": row.get("user_id"),
                    "batch_id": batch_id,
                    "bonus_result_id": bonus_result_id,
                    "whatsapp_number": number,
                    "message_body": message,
                    "status": "sending",
                }
            )
            .execute()
        )
    except Exception as exc:  # noqa: BLE001
        if is_unique_violation(exc):
            raise HTTPException(
                status_code=status.HTTP_409_CONFLICT,
                detail="A message for this user is already being sent or was already sent.",
            ) from exc
        raise
    attempt_id = inserted.data[0]["id"]
    _save_status(db, owner_id, bonus_result_id, "sending", None, None)

    try:
        outcome = no1api_client.send_text(number, message)
    except ProviderOutcomeUnknown as exc:
        logger.warning("No1API outcome unknown for result %s: %s", bonus_result_id, exc)
        return _finish(db, owner_id, bonus_result_id, attempt_id, "unknown", error=str(exc) or UNKNOWN_OUTCOME)
    except (ProviderSendError, ProviderNotConfigured) as exc:
        return _finish(db, owner_id, bonus_result_id, attempt_id, "failed", error=str(exc) or "The provider rejected the message.")
    except Exception as exc:  # noqa: BLE001
        # Could have failed before or after the provider processed it: not provably unsent.
        logger.error("No1API send failed unexpectedly (%s)", safe_error(exc))
        return _finish(
            db, owner_id, bonus_result_id, attempt_id, "unknown",
            error=f"Unexpected error in the server ({type(exc).__name__}). {UNKNOWN_OUTCOME}",
        )
    return _finish(db, owner_id, bonus_result_id, attempt_id, "sent", provider_id=outcome.provider_message_id)


def _finish(
    db: Client,
    owner_id: str,
    bonus_result_id: str,
    attempt_id: str,
    final: str,
    error: Optional[str] = None,
    provider_id: Optional[str] = None,
) -> WhatsAppSendResponse:
    now = _now().isoformat()
    sent_at = now if final == "sent" else None
    # If this save fails the attempt stays 'sending' (blocking duplicates) and
    # the stale-sending rule later turns it into an 'unknown' outcome.
    db.table("whatsapp_sends").update(
        {"status": final, "error_message": error, "provider_message_id": provider_id, "updated_at": now}
    ).eq("id", attempt_id).execute()
    _save_status(db, owner_id, bonus_result_id, final, error, sent_at)
    return WhatsAppSendResponse(bonus_result_id=bonus_result_id, send_status=final, send_error=error, sent_at=sent_at)


# --- single send ------------------------------------------------------------------


def send_bonus_message(
    db: Client, owner_id: str, report_id: str, bonus_result_id: str, payload: WhatsAppSendRequest
) -> WhatsAppSendResponse:
    row = get_bonus_result_by_id(db, owner_id, report_id, bonus_result_id)
    if row is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail=f"No result found with id {bonus_result_id}")
    _require_provider()
    return _attempt(db, owner_id, report_id, row, payload.message, acknowledge_unknown=payload.acknowledge_unknown)


# --- test number ------------------------------------------------------------------


def send_test_message(db: Client, owner_id: str, payload: WhatsAppTestRequest) -> WhatsAppTestResponse:
    if not payload.authorized:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail="Confirm that you are authorized to message this test number.",
        )
    number = normalize_whatsapp_number(payload.whatsapp_number)
    if number is None:
        raise HTTPException(status_code=status.HTTP_422_UNPROCESSABLE_ENTITY, detail="A test number is required.")
    message = payload.message.strip()
    if not message:
        raise HTTPException(status_code=status.HTTP_422_UNPROCESSABLE_ENTITY, detail="The message cannot be empty.")
    _require_provider()

    error: Optional[str] = None
    provider_id: Optional[str] = None
    try:
        provider_id = no1api_client.send_text(number, message).provider_message_id
        final = "sent"
    except ProviderOutcomeUnknown as exc:
        final, error = "unknown", str(exc) or UNKNOWN_OUTCOME
    except (ProviderSendError, ProviderNotConfigured) as exc:
        final, error = "failed", str(exc) or "The provider rejected the message."
    except Exception as exc:  # noqa: BLE001
        logger.error("No1API test send failed unexpectedly (%s)", safe_error(exc))
        final, error = "unknown", UNKNOWN_OUTCOME
    db.table("whatsapp_test_sends").insert(
        {
            "owner_id": owner_id,
            "whatsapp_number": number,
            "message_body": message,
            "status": final,
            "provider_message_id": provider_id,
            "error_message": error,
        }
    ).execute()
    return WhatsAppTestResponse(status=final, error=error)


def test_status(db: Client, owner_id: str) -> WhatsAppTestStatus:
    rows = (
        db.table("whatsapp_test_sends").select("id").eq("owner_id", owner_id).eq("status", "sent").limit(1).execute().data
    )
    return WhatsAppTestStatus(tested=bool(rows), provider_available=no1api_client.is_available())


# --- bulk ---------------------------------------------------------------------------


def start_bulk(
    db: Client, owner_id: str, report_id: str, payload: WhatsAppBulkRequest
) -> Tuple[str, List[Tuple[dict, str]]]:
    """Validates and records a bulk run; returns (batch_id, queue). The queue
    is then processed by run_bulk in the background."""
    settings = get_settings()
    if not payload.confirmed:
        raise HTTPException(status_code=status.HTTP_422_UNPROCESSABLE_ENTITY, detail="Bulk sending must be confirmed.")
    if len(payload.items) > settings.WHATSAPP_BULK_MAX:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail=f"At most {settings.WHATSAPP_BULK_MAX} messages can be sent in one run.",
        )
    _require_provider()
    if not test_status(db, owner_id).tested:
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail="Send a test message to an authorized test number first. Nothing was sent.",
        )
    active = (
        db.table("whatsapp_batches").select("id, updated_at").eq("owner_id", owner_id).eq("status", "running").execute().data
        or []
    )
    for b in active:
        updated = _parse(b.get("updated_at"))
        if updated and _now() - updated <= timedelta(seconds=STALE_SENDING_SECONDS):
            raise HTTPException(
                status_code=status.HTTP_409_CONFLICT, detail="Another bulk send is still running. Wait for it to finish."
            )

    rows = {r["id"]: r for r in get_bonus_results_for_report(db, owner_id, report_id)}
    queue: List[Tuple[dict, str]] = []
    skipped: List[dict] = []
    seen = set()
    for item in payload.items:
        rid = item.bonus_result_id
        if rid in seen:
            continue
        seen.add(rid)
        row = rows.get(rid)
        if row is None:
            skipped.append({"bonus_result_id": rid, "user_name": None, "reason": "Not part of this report."})
            continue
        name = (row.get("users") or {}).get("name")
        _number, reason = _eligibility(row)
        if reason is None and row.get("whatsapp_send_status") == "sent":
            reason = "Already sent."
        if reason is None and row.get("whatsapp_send_status") == "sending":
            reason = "A send is already in progress."
        if reason is None and row.get("whatsapp_send_status") == "unknown":
            reason = "Last attempt's outcome is unknown. Check WhatsApp, then retry this user individually."
        if not item.message.strip():
            reason = reason or "Empty message."
        if reason:
            skipped.append({"bonus_result_id": rid, "user_name": name, "reason": reason})
        else:
            queue.append((row, item.message))

    batch_id = str(uuid4())
    db.table("whatsapp_batches").insert(
        {
            "id": batch_id,
            "owner_id": owner_id,
            "report_id": report_id,
            "status": "running" if queue else "completed",
            "total_queued": len(queue),
            "skipped": skipped,
            "finished_at": None if queue else _now().isoformat(),
        }
    ).execute()
    return batch_id, queue


def run_bulk(db: Client, owner_id: str, report_id: str, batch_id: str, queue: List[Tuple[dict, str]]) -> None:
    """Background worker: one message at a time, pausing between them."""
    interval = max(0.0, get_settings().NO1API_MIN_INTERVAL_SECONDS)
    runtime_skipped: List[dict] = []
    try:
        for index, (row, message) in enumerate(queue):
            if index:
                _sleep(interval)
            try:
                _attempt(db, owner_id, report_id, row, message, batch_id=batch_id)
            except HTTPException as exc:
                runtime_skipped.append(
                    {"bonus_result_id": row["id"], "user_name": (row.get("users") or {}).get("name"), "reason": str(exc.detail)}
                )
            except Exception as exc:  # noqa: BLE001
                logger.error("Bulk send item failed (%s)", safe_error(exc))
                runtime_skipped.append(
                    {"bonus_result_id": row["id"], "user_name": (row.get("users") or {}).get("name"), "reason": "Unexpected error."}
                )
            _heartbeat(db, owner_id, batch_id)
    finally:
        batch = db.table("whatsapp_batches").select("skipped, total_queued").eq("id", batch_id).limit(1).execute().data
        update = {"status": "completed", "finished_at": _now().isoformat(), "updated_at": _now().isoformat()}
        if batch and runtime_skipped:
            update["skipped"] = list(batch[0]["skipped"] or []) + runtime_skipped
            update["total_queued"] = batch[0]["total_queued"] - len(runtime_skipped)
        db.table("whatsapp_batches").update(update).eq("id", batch_id).execute()


def _heartbeat(db: Client, owner_id: str, batch_id: str) -> None:
    db.table("whatsapp_batches").update({"updated_at": _now().isoformat()}).eq("id", batch_id).eq(
        "owner_id", owner_id
    ).execute()


def bulk_progress(db: Client, owner_id: str, report_id: str, batch_id: str) -> WhatsAppBulkProgress:
    found = (
        db.table("whatsapp_batches")
        .select("*")
        .eq("owner_id", owner_id)
        .eq("report_id", report_id)
        .eq("id", batch_id)
        .limit(1)
        .execute()
        .data
        if _is_uuid(batch_id)
        else []
    )
    if not found:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="No such bulk run.")
    batch = found[0]
    attempts = (
        db.table("whatsapp_sends").select("bonus_result_id, status, error_message").eq("owner_id", owner_id).eq("batch_id", batch_id).execute().data
        or []
    )
    counts: Dict[str, int] = {"sent": 0, "failed": 0, "unknown": 0}
    bad_ids: List[str] = []
    errors: Dict[str, Tuple[str, Optional[str]]] = {}
    for a in attempts:
        st = a["status"]
        if st in counts:
            counts[st] += 1
        if st in ("failed", "unknown"):
            bad_ids.append(a["bonus_result_id"])
            errors[a["bonus_result_id"]] = (st, a.get("error_message"))
    names: Dict[str, Optional[str]] = {}
    for chunk in chunked(bad_ids, 100):
        for r in db.table("bonus_results").select("id, users(name)").in_("id", chunk).execute().data or []:
            names[r["id"]] = (r.get("users") or {}).get("name")

    queued = int(batch.get("total_queued") or 0)
    done = sum(counts.values())
    run_status = batch["status"]
    updated = _parse(batch.get("updated_at"))
    if run_status == "running" and updated and _now() - updated > timedelta(seconds=STALE_SENDING_SECONDS):
        run_status = "interrupted"
    skipped = [BulkSkipped(**s) for s in (batch.get("skipped") or [])]
    return WhatsAppBulkProgress(
        batch_id=batch_id,
        status=run_status,
        total_selected=queued + len(skipped),
        queued=queued,
        skipped=skipped,
        sent=counts["sent"],
        failed=counts["failed"],
        unknown=counts["unknown"],
        pending=max(0, queued - done),
        items=[
            BulkItemStatus(bonus_result_id=i, user_name=names.get(i), send_status=errors[i][0], send_error=errors[i][1])
            for i in bad_ids
        ],
    )


def _is_uuid(value: str) -> bool:
    from app.services.reports_service import is_valid_uuid

    return is_valid_uuid(value)
