"""
Send bonus messages through the server-side No1API integration.

The recipient is always the number saved for the user (never taken from the
request), results must belong to the signed-in admin, and credentials never
leave the server. Bulk runs are confirmed, test-gated and processed in the
background, one message at a time.
"""

from fastapi import APIRouter, BackgroundTasks, Depends
from supabase import Client

from app.api.deps import CurrentUser, get_current_user, get_db, get_report_or_404
from app.schemas.whatsapp import (
    WhatsAppBulkProgress,
    WhatsAppBulkRequest,
    WhatsAppSendRequest,
    WhatsAppSendResponse,
    WhatsAppTestRequest,
    WhatsAppTestResponse,
    WhatsAppTestStatus,
)
from app.services import whatsapp_service as svc

router = APIRouter(prefix="/reports", tags=["WhatsApp"])
tools_router = APIRouter(prefix="/whatsapp", tags=["WhatsApp"])


@router.post(
    "/{report_id}/results/{bonus_result_id}/whatsapp-send",
    response_model=WhatsAppSendResponse,
    summary="Send this result's bonus message via No1API (one active/sent attempt per result)",
)
def whatsapp_send(
    report_id: str,
    bonus_result_id: str,
    payload: WhatsAppSendRequest,
    current_user: CurrentUser = Depends(get_current_user),
    db: Client = Depends(get_db),
) -> WhatsAppSendResponse:
    get_report_or_404(db, current_user.id, report_id)
    return svc.send_bonus_message(db, current_user.id, report_id, bonus_result_id, payload)


@router.post(
    "/{report_id}/whatsapp-bulk",
    response_model=WhatsAppBulkProgress,
    summary="Start a confirmed, rate-limited background bulk send (needs a prior successful test message)",
)
def whatsapp_bulk(
    report_id: str,
    payload: WhatsAppBulkRequest,
    background: BackgroundTasks,
    current_user: CurrentUser = Depends(get_current_user),
    db: Client = Depends(get_db),
) -> WhatsAppBulkProgress:
    get_report_or_404(db, current_user.id, report_id)
    batch_id, queue = svc.start_bulk(db, current_user.id, report_id, payload)
    if queue:
        background.add_task(svc.run_bulk, db, current_user.id, report_id, batch_id, queue)
    return svc.bulk_progress(db, current_user.id, report_id, batch_id)


@router.get(
    "/{report_id}/whatsapp-bulk/{batch_id}",
    response_model=WhatsAppBulkProgress,
    summary="Progress of a bulk send",
)
def whatsapp_bulk_progress(
    report_id: str,
    batch_id: str,
    current_user: CurrentUser = Depends(get_current_user),
    db: Client = Depends(get_db),
) -> WhatsAppBulkProgress:
    get_report_or_404(db, current_user.id, report_id)
    return svc.bulk_progress(db, current_user.id, report_id, batch_id)


@tools_router.get("/test-status", response_model=WhatsAppTestStatus, summary="Has a test message been accepted yet?")
def whatsapp_test_status(
    current_user: CurrentUser = Depends(get_current_user), db: Client = Depends(get_db)
) -> WhatsAppTestStatus:
    return svc.test_status(db, current_user.id)


@tools_router.post("/test-send", response_model=WhatsAppTestResponse, summary="Send one test message to an authorized number")
def whatsapp_test_send(
    payload: WhatsAppTestRequest,
    current_user: CurrentUser = Depends(get_current_user),
    db: Client = Depends(get_db),
) -> WhatsAppTestResponse:
    return svc.send_test_message(db, current_user.id, payload)
