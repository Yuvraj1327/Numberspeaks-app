"""
Referral Ledger (every referral entry across all weeks) and Referrers
(persistent referrer details). Entries still belong to one weekly report;
this is the cross-period view plus manual entry/edit/delete.
"""

from typing import List

from fastapi import APIRouter, Depends, HTTPException, Response, status
from supabase import Client

from app.api.deps import CurrentUser, assert_report_modifiable, get_current_user, get_db, get_report_or_404
from app.schemas.referral import (
    LedgerCreate,
    ReferralEntry,
    ReferralUpdate,
    Referrer,
    ReferrerIn,
    ReferrerUpdate,
)
from app.services import referral_service
from app.services.referral_service import ledger as load_ledger
from app.services.report_locks import report_busy_guard

router = APIRouter(tags=["Referrals"])


@router.get("/referral-ledger", response_model=List[ReferralEntry], summary="Every referral entry, all weeks")
def get_ledger(current_user: CurrentUser = Depends(get_current_user), db: Client = Depends(get_db)):
    return load_ledger(db, current_user.id)


@router.post(
    "/referral-ledger",
    response_model=ReferralEntry,
    status_code=status.HTTP_201_CREATED,
    summary="Manually add referral activity for a week",
)
def add_ledger_entry(body: LedgerCreate, current_user: CurrentUser = Depends(get_current_user), db: Client = Depends(get_db)):
    with report_busy_guard(body.report_id, "referral change"):
        report = get_report_or_404(db, current_user.id, body.report_id)
        assert_report_modifiable(db, current_user.id, report)
        return referral_service.create_entry(db, current_user.id, report, body)


def _entry_report(db: Client, owner_id: str, entry_id: str) -> dict:
    for e in load_ledger(db, owner_id):
        if e.entry_id == entry_id:
            return get_report_or_404(db, owner_id, e.report_id)
    raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Referral entry not found.")


@router.patch("/referral-ledger/{entry_id}", response_model=ReferralEntry, summary="Edit a ledger entry's rate/amount/note")
def edit_ledger_entry(
    entry_id: str, body: ReferralUpdate, current_user: CurrentUser = Depends(get_current_user), db: Client = Depends(get_db)
):
    report = _entry_report(db, current_user.id, entry_id)
    with report_busy_guard(report["id"], "referral change"):
        assert_report_modifiable(db, current_user.id, report)
        return referral_service.update_entry(db, current_user.id, report, entry_id, body)


@router.delete("/referral-ledger/{entry_id}", status_code=status.HTTP_204_NO_CONTENT, summary="Delete a ledger entry")
def delete_ledger_entry(entry_id: str, current_user: CurrentUser = Depends(get_current_user), db: Client = Depends(get_db)):
    report = _entry_report(db, current_user.id, entry_id)
    with report_busy_guard(report["id"], "referral change"):
        assert_report_modifiable(db, current_user.id, report)
        referral_service.delete_entry(db, current_user.id, report, entry_id)
    return Response(status_code=status.HTTP_204_NO_CONTENT)


@router.get("/referrers", response_model=List[Referrer], summary="Saved referrers with their totals")
def get_referrers(current_user: CurrentUser = Depends(get_current_user), db: Client = Depends(get_db)):
    return referral_service.list_referrers(db, current_user.id)


@router.post("/referrers", response_model=Referrer, status_code=status.HTTP_201_CREATED, summary="Create a referrer")
def add_referrer(body: ReferrerIn, current_user: CurrentUser = Depends(get_current_user), db: Client = Depends(get_db)):
    return referral_service.create_referrer(db, current_user.id, body)


@router.patch("/referrers/{referrer_id}", response_model=Referrer, summary="Edit referrer details")
def edit_referrer(
    referrer_id: str, body: ReferrerUpdate, current_user: CurrentUser = Depends(get_current_user), db: Client = Depends(get_db)
):
    return referral_service.update_referrer(db, current_user.id, referrer_id, body)


@router.delete("/referrers/{referrer_id}", status_code=status.HTTP_204_NO_CONTENT, summary="Remove saved referrer details")
def remove_referrer(referrer_id: str, current_user: CurrentUser = Depends(get_current_user), db: Client = Depends(get_db)):
    referral_service.delete_referrer(db, current_user.id, referrer_id)
    return Response(status_code=status.HTTP_204_NO_CONTENT)
