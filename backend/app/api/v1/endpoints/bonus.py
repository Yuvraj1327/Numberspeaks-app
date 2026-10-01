"""
Bonus calculation and results endpoints.

Flow: a report must already be validated (Step 4, status == "validated")
before calculation can start. Calculation re-validates each row defensively,
computes a bonus per user independently via app/services/bonus_calculator.py
(the client's real formula: 3% of a loss, 0 otherwise), saves it to
bonus_results, and updates the report's status. Results can then be listed
for the whole report or looked up for one user, each joined with its
latest WhatsApp send outcome for the admin results view.

POST /calculate-bonus still returns 501 Not Implemented, unmodified, in
the (now hypothetical) case bonus_calculator.is_formula_configured() ever
returns False again — nothing here invents a number in its place.
"""

import logging

from fastapi import APIRouter, Depends, HTTPException, status

from app.core.auth import AuthUser, can_access_report, get_current_user
from app.db.supabase_client import SupabaseNotConfiguredError, get_supabase
from app.schemas.bonus import BonusCalculationSummary, BonusResult
from app.services.bonus_calculator import BonusFormulaNotConfiguredError
from app.services.bonus_service import run_bonus_calculation
from app.services.reports_service import (
    ACTIVE_STATUSES,
    get_bonus_result_for_user,
    get_bonus_results_for_report,
    get_latest_whatsapp_status,
    get_report,
    latest_whatsapp_status_of_row,
    safe_error,
    to_bonus_result,
    update_report_status,
)

logger = logging.getLogger("numberspeaks")

router = APIRouter(prefix="/reports", tags=["Bonus"])


def _get_db():
    try:
        return get_supabase()
    except SupabaseNotConfiguredError as exc:
        raise HTTPException(status_code=status.HTTP_503_SERVICE_UNAVAILABLE, detail=str(exc)) from exc


def _get_report_or_404(db, report_id: str, user: AuthUser) -> dict:
    try:
        report = get_report(db, report_id)
    except Exception as exc:  # noqa: BLE001
        logger.exception("Failed to look up report %s", report_id)
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail=f"Could not read report from the database: {exc}",
        ) from exc

    # Someone else's report is reported exactly like a missing one.
    if report is None or not can_access_report(report, user):
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail=f"No report found with id {report_id}")
    return report


@router.post(
    "/{report_id}/calculate-bonus",
    response_model=BonusCalculationSummary,
    summary="Calculate and save the bonus for every user in a validated report",
)
def calculate_bonus_for_report(report_id: str, user: AuthUser = Depends(get_current_user)) -> BonusCalculationSummary:
    db = _get_db()
    report = _get_report_or_404(db, report_id, user)

    if report.get("status") in ACTIVE_STATUSES:
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail=(
                f"This report is still being processed in the background "
                f"(current status: {report.get('status')!r}). "
                f"Check GET /api/v1/reports/{report_id}/status."
            ),
        )

    if report.get("status") != "validated":
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail=(
                f"Report must be validated before bonus calculation can run "
                f"(current status: {report.get('status')!r}). "
                f"Call POST /api/v1/reports/{report_id}/validate first."
            ),
        )

    try:
        rows = get_bonus_results_for_report(db, report_id)
    except Exception as exc:  # noqa: BLE001
        logger.exception("Failed to load rows for report %s", report_id)
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail=f"Could not read this report's rows: {exc}",
        ) from exc

    try:
        calculated_count, results, errors = run_bonus_calculation(db, rows)
    except BonusFormulaNotConfiguredError as exc:
        # A system-configuration issue, not a problem with this report's
        # data — leave the report's status untouched.
        raise HTTPException(status_code=status.HTTP_501_NOT_IMPLEMENTED, detail=str(exc)) from exc
    except Exception as exc:  # noqa: BLE001
        logger.exception("Unexpected error during bonus calculation for report %s", report_id)
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail=f"Unexpected error during bonus calculation: {exc}",
        ) from exc

    new_status = "completed" if calculated_count > 0 else "failed"
    update_report_status(db, report_id, new_status)

    return BonusCalculationSummary(
        report_id=report_id,
        status=new_status,
        total_input_records=len(rows),
        calculated_count=calculated_count,
        failed_count=len(errors),
        results=results,
        errors=errors,
    )


@router.get(
    "/{report_id}/results",
    response_model=list[BonusResult],
    summary="Get bonus results for a report",
)
def get_report_results(report_id: str, user: AuthUser = Depends(get_current_user)) -> list[BonusResult]:
    db = _get_db()
    _get_report_or_404(db, report_id, user)

    try:
        # The latest WhatsApp status of every row comes back in the same
        # request; if that table isn't available, fall back to plain rows.
        try:
            rows = get_bonus_results_for_report(db, report_id, include_whatsapp=True)
        except Exception as exc:  # noqa: BLE001
            logger.warning("Could not read WhatsApp status for report %s: %s", report_id, safe_error(exc))
            rows = get_bonus_results_for_report(db, report_id)
    except Exception as exc:  # noqa: BLE001
        logger.error("Failed to load results for report %s: %s", report_id, safe_error(exc))
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="Could not read this report's results.",
        ) from exc

    return [to_bonus_result(row, whatsapp_status=latest_whatsapp_status_of_row(row)) for row in rows]


@router.get(
    "/{report_id}/results/{user_id}",
    response_model=BonusResult,
    summary="Get one user's bonus result for a report",
)
def get_user_result(report_id: str, user_id: str, user: AuthUser = Depends(get_current_user)) -> BonusResult:
    db = _get_db()
    _get_report_or_404(db, report_id, user)

    try:
        row = get_bonus_result_for_user(db, report_id, user_id)
    except Exception as exc:  # noqa: BLE001
        logger.exception("Failed to load result for user %s on report %s", user_id, report_id)
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail=f"Could not read this user's result: {exc}",
        ) from exc

    if row is None:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail=f"No bonus result found for user {user_id} on report {report_id}",
        )

    try:
        wa_status = get_latest_whatsapp_status(db, row["id"])
    except Exception as exc:  # noqa: BLE001
        logger.warning("Could not read WhatsApp status for bonus_result %s: %s", row["id"], exc)
        wa_status = None

    return to_bonus_result(row, whatsapp_status=wa_status)
