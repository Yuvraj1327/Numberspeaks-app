"""
WhatsApp send endpoint (Step 7).

Requires the report's bonuses to already be calculated
(report.status == "completed", from Steps 5-6) — this endpoint only sends
what was already computed, it never calculates anything itself.
"""

import logging

from fastapi import APIRouter, HTTPException, Query, status

from app.db.supabase_client import SupabaseNotConfiguredError, get_supabase
from app.schemas.whatsapp import WhatsAppSendSummary
from app.services.reports_service import get_report
from app.services.whatsapp_client import WhatsAppNotConfiguredError
from app.services.whatsapp_service import send_bonus_whatsapp_for_report

logger = logging.getLogger("numberspeaks")

router = APIRouter(prefix="/reports", tags=["WhatsApp"])


@router.post(
    "/{report_id}/send-whatsapp",
    response_model=WhatsAppSendSummary,
    summary="Send each user's calculated bonus to their WhatsApp number",
)
async def send_whatsapp_for_report(
    report_id: str,
    force: bool = Query(
        False,
        description="Resend even to users who already have a successfully sent message for this report.",
    ),
) -> WhatsAppSendSummary:
    try:
        db = get_supabase()
    except SupabaseNotConfiguredError as exc:
        raise HTTPException(status_code=status.HTTP_503_SERVICE_UNAVAILABLE, detail=str(exc)) from exc

    try:
        report = get_report(db, report_id)
    except Exception as exc:  # noqa: BLE001
        logger.exception("Failed to look up report %s", report_id)
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail=f"Could not read report from the database: {exc}",
        ) from exc

    if report is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail=f"No report found with id {report_id}")

    if report.get("status") != "completed":
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail=(
                f"Bonuses must be calculated before sending WhatsApp messages "
                f"(current report status: {report.get('status')!r}). "
                f"Call POST /api/v1/reports/{report_id}/calculate-bonus first."
            ),
        )

    try:
        return send_bonus_whatsapp_for_report(db, report_id, force=force)
    except WhatsAppNotConfiguredError as exc:
        raise HTTPException(status_code=status.HTTP_503_SERVICE_UNAVAILABLE, detail=str(exc)) from exc
    except Exception as exc:  # noqa: BLE001
        logger.exception("Unexpected error sending WhatsApp messages for report %s", report_id)
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail=f"Unexpected error while sending WhatsApp messages: {exc}",
        ) from exc
