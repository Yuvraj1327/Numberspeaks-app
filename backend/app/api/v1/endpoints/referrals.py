"""
Referral entry endpoints (per report/period).

The admin links a referred user to their referrer for a period. The
adjustment itself is computed when the report is calculated (10% by
default, configurable). Duplicate / double-counted entries are rejected.
"""

from typing import List

from fastapi import APIRouter, Depends, status
from supabase import Client

from app.api.deps import CurrentUser, assert_report_modifiable, get_current_user, get_db, get_report_or_404
from app.schemas.referral import ReferralCreate, ReferralEntry
from app.services import referral_service

router = APIRouter(prefix="/reports", tags=["Referrals"])


@router.get(
    "/{report_id}/referrals",
    response_model=List[ReferralEntry],
    summary="List the referral entries of a report (period)",
)
async def list_referrals(
    report_id: str,
    current_user: CurrentUser = Depends(get_current_user),
    db: Client = Depends(get_db),
) -> List[ReferralEntry]:
    get_report_or_404(db, current_user.id, report_id)
    return referral_service.list_entries(db, current_user.id, report_id)


@router.post(
    "/{report_id}/referrals",
    response_model=ReferralEntry,
    status_code=status.HTTP_201_CREATED,
    summary="Add a referral entry (referrer + referred user) for this period",
)
async def add_referral(
    report_id: str,
    payload: ReferralCreate,
    current_user: CurrentUser = Depends(get_current_user),
    db: Client = Depends(get_db),
) -> ReferralEntry:
    report = get_report_or_404(db, current_user.id, report_id)
    assert_report_modifiable(db, current_user.id, report)
    return referral_service.create_entry(db, current_user.id, report, payload)


@router.delete(
    "/{report_id}/referrals/{entry_id}",
    status_code=status.HTTP_204_NO_CONTENT,
    summary="Remove a referral entry",
)
async def remove_referral(
    report_id: str,
    entry_id: str,
    current_user: CurrentUser = Depends(get_current_user),
    db: Client = Depends(get_db),
) -> None:
    report = get_report_or_404(db, current_user.id, report_id)
    assert_report_modifiable(db, current_user.id, report)
    referral_service.delete_entry(db, current_user.id, report, entry_id)
