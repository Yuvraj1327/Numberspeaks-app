"""
WhatsApp "opened" record.

The backend does NOT send WhatsApp messages. The app opens a wa.me link on
the admin's own device with the message pre-filled; once that link has
actually been opened it calls this endpoint so the fact is recorded. The
record means "the admin opened WhatsApp for this user" — never "sent" or
"delivered".
"""

from fastapi import APIRouter, Depends
from supabase import Client

from app.api.deps import CurrentUser, get_current_user, get_db, get_report_or_404
from app.schemas.whatsapp import WhatsAppInitiatedRequest, WhatsAppInitiatedResponse
from app.services.whatsapp_service import record_initiation

router = APIRouter(prefix="/reports", tags=["WhatsApp"])


@router.post(
    "/{report_id}/results/{bonus_result_id}/whatsapp-initiated",
    response_model=WhatsAppInitiatedResponse,
    summary="Record that WhatsApp was opened with a pre-filled message for this result",
)
def whatsapp_initiated(
    report_id: str,
    bonus_result_id: str,
    payload: WhatsAppInitiatedRequest,
    current_user: CurrentUser = Depends(get_current_user),
    db: Client = Depends(get_db),
) -> WhatsAppInitiatedResponse:
    get_report_or_404(db, current_user.id, report_id)
    return record_initiation(db, current_user.id, report_id, bonus_result_id, payload)
