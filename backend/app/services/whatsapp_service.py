"""
Records that the admin OPENED WhatsApp with a pre-filled message.

The backend does not send WhatsApp messages and has no WhatsApp provider
integration: the app opens a `wa.me` link on the admin's device, and the
admin presses Send inside WhatsApp themselves. All the backend can know —
and all it records — is "the admin opened WhatsApp for this user with this
text at this time". That is deliberately NOT called "sent" or "delivered".
"""

from datetime import datetime, timezone

from fastapi import HTTPException, status
from supabase import Client

from app.schemas.whatsapp import WhatsAppInitiatedRequest, WhatsAppInitiatedResponse
from app.services.reports_service import get_bonus_result_by_id
from app.services.users_service import normalize_whatsapp_number


def record_initiation(
    db: Client,
    owner_id: str,
    report_id: str,
    bonus_result_id: str,
    payload: WhatsAppInitiatedRequest,
) -> WhatsAppInitiatedResponse:
    row = get_bonus_result_by_id(db, owner_id, report_id, bonus_result_id)
    if row is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail=f"No result found with id {bonus_result_id}")

    payable = row.get("bonus_amount")
    if row.get("calculation_status") != "calculated" or payable is None or float(payable) <= 0:
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail="This user has no payable bonus, so there is no bonus message to send.",
        )

    number = normalize_whatsapp_number(payload.whatsapp_number)
    if number is None:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY, detail="A WhatsApp number is required."
        )

    now = datetime.now(timezone.utc).isoformat()
    count = int(row.get("whatsapp_initiated_count") or 0) + 1

    db.table("whatsapp_initiations").insert(
        {
            "owner_id": owner_id,
            "bonus_result_id": bonus_result_id,
            "whatsapp_number": number,
            "message_body": payload.message,
            "initiated_at": now,
        }
    ).execute()
    db.table("bonus_results").update({"whatsapp_initiated_at": now, "whatsapp_initiated_count": count}).eq(
        "owner_id", owner_id
    ).eq("id", bonus_result_id).execute()

    return WhatsAppInitiatedResponse(
        bonus_result_id=bonus_result_id,
        whatsapp_status="initiated",
        whatsapp_initiated_at=now,
        whatsapp_initiated_count=count,
    )
