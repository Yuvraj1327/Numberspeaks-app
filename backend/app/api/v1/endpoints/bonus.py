"""
Bonus calculation and results endpoints.

Flow: a report must already be validated (status == "validated") before the
admin confirms the calculation. Calculation re-validates each row
defensively, applies the confirmed rules (app/services/bonus_calculator.py:
personal 3%, referral 10%, carry-forward — rates configurable), saves the
full breakdown, and updates the report's status. Results can then be listed
for the whole report or looked up for one user.

Every endpoint requires a logged-in admin and only ever touches that
admin's own data.
"""

import logging
from datetime import datetime, timezone
from typing import List

from fastapi import APIRouter, Depends, HTTPException, status
from supabase import Client

from app.api.deps import CurrentUser, assert_report_modifiable, get_current_user, get_db, get_report_or_404
from app.schemas.bonus import BonusCalculationSummary, BonusResult
from app.services.report_locks import report_busy_guard
from app.services.bonus_service import run_bonus_calculation
from app.services.referral_service import annotate_results
from app.services.reports_service import (
    get_bonus_result_for_user,
    get_bonus_results_for_report,
    to_bonus_result,
    update_report_status,
    update_report_summary,
)

logger = logging.getLogger("numberspeaks")

router = APIRouter(prefix="/reports", tags=["Bonus"])


@router.post(
    "/{report_id}/calculate-bonus",
    response_model=BonusCalculationSummary,
    summary="Confirm: calculate and save the bonus for every user in a validated report",
)
def calculate_bonus_for_report(
    report_id: str,
    current_user: CurrentUser = Depends(get_current_user),
    db: Client = Depends(get_db),
) -> BonusCalculationSummary:
    with report_busy_guard(report_id, "calculation"):
        return _calculate(db, current_user.id, report_id)


def _calculate(db: Client, owner_id: str, report_id: str) -> BonusCalculationSummary:
    report = get_report_or_404(db, owner_id, report_id)

    if report.get("status") != "validated":
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail=(
                f"Report must be validated before bonus calculation can run "
                f"(current status: {report.get('status')!r}). "
                f"Call POST /api/v1/reports/{report_id}/validate first."
            ),
        )

    # Refuse to calculate an older period once a newer one is already
    # calculated: its carried-forward balances would no longer line up.
    assert_report_modifiable(db, owner_id, report)

    rows = get_bonus_results_for_report(db, owner_id, report_id)

    try:
        calculated_count, results, errors = run_bonus_calculation(db, owner_id, report, rows)
    except Exception as exc:  # noqa: BLE001
        logger.exception("Unexpected error during bonus calculation for report %s", report_id)
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail="Unexpected error during bonus calculation.",
        ) from exc

    new_status = "completed" if calculated_count > 0 else "failed"
    update_report_status(db, owner_id, report_id, new_status)

    total_payable = round(sum((r.payable_bonus or 0.0) for r in results), 2)
    payable_count = sum(1 for r in results if (r.payable_bonus or 0.0) > 0)
    if new_status == "completed":
        update_report_summary(
            db,
            owner_id,
            report_id,
            {
                "user_count": len(rows),
                "payable_user_count": payable_count,
                "total_payable": total_payable,
                "calculated_at": datetime.now(timezone.utc).isoformat(),
            },
        )

    return BonusCalculationSummary(
        report_id=report_id,
        status=new_status,
        total_input_records=len(rows),
        calculated_count=calculated_count,
        failed_count=len(errors),
        total_payable=total_payable,
        payable_user_count=payable_count,
        results=annotate_results(db, owner_id, report_id, results),
        errors=errors,
    )


@router.get(
    "/{report_id}/results",
    response_model=List[BonusResult],
    summary="Get bonus results for a report (also the extracted rows, for review)",
)
def get_report_results(
    report_id: str,
    current_user: CurrentUser = Depends(get_current_user),
    db: Client = Depends(get_db),
) -> List[BonusResult]:
    get_report_or_404(db, current_user.id, report_id)
    rows = get_bonus_results_for_report(db, current_user.id, report_id)
    return annotate_results(db, current_user.id, report_id, [to_bonus_result(row) for row in rows])


@router.get(
    "/{report_id}/results/{user_id}",
    response_model=BonusResult,
    summary="Get one user's bonus result for a report",
)
def get_user_result(
    report_id: str,
    user_id: str,
    current_user: CurrentUser = Depends(get_current_user),
    db: Client = Depends(get_db),
) -> BonusResult:
    get_report_or_404(db, current_user.id, report_id)
    row = get_bonus_result_for_user(db, current_user.id, report_id, user_id)
    if row is None:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail=f"No bonus result found for user {user_id} on report {report_id}",
        )
    return annotate_results(db, current_user.id, report_id, [to_bonus_result(row)])[0]
