"""
Bonus calculation orchestration.

This is the glue between validation (Step 4), the pure formula
(bonus_calculator.py), and Supabase — it does not contain any formula
logic itself, and it does not talk to Supabase for anything beyond saving
the result of a calculation that already happened.

Each row is validated and calculated independently in memory: one bad
row is recorded as an error and skipped, it never stops the rest of the
report from being calculated. The results are then written to Supabase in
bulk (one request per batch of rows), not one request per row.
"""

import logging
from typing import Callable, List, Optional, Tuple

from supabase import Client

from app.schemas.bonus import BonusCalculationError, BonusResult
from app.schemas.validation import InvalidRecord
from app.services.bonus_calculator import BonusFormulaNotConfiguredError, BonusInput, calculate_bonus, is_formula_configured
from app.services.reports_service import (
    bonus_result_row_to_raw,
    bulk_update_bonus_results,
    default_row_reference,
    safe_error,
    to_bonus_result,
)
from app.services.validation import validate_record

logger = logging.getLogger("numberspeaks")


def run_bonus_calculation(
    db: Client,
    rows: List[dict],
    heartbeat: Optional[Callable[[], None]] = None,
) -> Tuple[int, List[BonusResult], List[BonusCalculationError]]:
    """
    Validates, calculates, and saves a bonus for each row.

    Returns (calculated_count, results, errors). Raises
    BonusFormulaNotConfiguredError immediately, before touching any row or
    the database, if the client's formula hasn't been implemented yet.
    """
    if not is_formula_configured():
        raise BonusFormulaNotConfiguredError(
            "No bonus formula has been configured yet. Implement calculate_bonus() "
            "in app/services/bonus_calculator.py, then set is_formula_configured() "
            "in the same file to return True."
        )

    errors: List[BonusCalculationError] = []
    to_calculate: List[Tuple[dict, float]] = []  # (row, bonus amount)
    invalid_rows: List[dict] = []

    for row in rows:
        user = row.get("users") or {}
        user_name = user.get("name")
        bonus_result_id = row.get("id")

        raw = bonus_result_row_to_raw(row)
        reference = default_row_reference(raw, 0)
        outcome = validate_record(raw, reference)

        if outcome is None:
            # Blank/leftover-header row — shouldn't occur in stored data,
            # but skip consistently with Step 4 rather than erroring.
            continue

        if isinstance(outcome, InvalidRecord):
            errors.append(
                BonusCalculationError(
                    bonus_result_id=bonus_result_id, user_name=user_name, issues=outcome.issues
                )
            )
            invalid_rows.append(row)
            continue

        bonus_input = BonusInput(
            user_name=outcome.user_name,
            level=outcome.level,
            casino_pts=outcome.casino_pts,
            sport_pts=outcome.sport_pts,
            third_party_pts=outcome.third_party_pts,
            profit_loss=outcome.profit_loss,
            ptype=outcome.ptype,
        )

        try:
            amount = calculate_bonus(bonus_input)
        except BonusFormulaNotConfiguredError:
            raise
        except Exception as exc:  # noqa: BLE001
            logger.warning("Bonus calculation failed for row %s: %s", bonus_result_id, safe_error(exc))
            errors.append(
                BonusCalculationError(
                    bonus_result_id=bonus_result_id,
                    user_name=user_name,
                    issues=[f"Calculation failed: {safe_error(exc)}"],
                )
            )
            invalid_rows.append(row)
            continue

        to_calculate.append((row, amount))

    # --- Save: one bulk request per batch, not one per row ------------------
    def key_fields(row: dict) -> dict:
        return {
            "id": row["id"],
            "report_id": row["report_id"],
            "user_id": row.get("user_id") or (row.get("users") or {}).get("id"),
        }

    if invalid_rows:
        failed_invalid = bulk_update_bonus_results(
            db,
            [{**key_fields(row), "calculation_status": "invalid"} for row in invalid_rows],
            heartbeat,
        )
        if failed_invalid:
            logger.warning("Could not persist 'invalid' status for %d rows", len(failed_invalid))

    failed_ids = set()
    if to_calculate:
        failed = bulk_update_bonus_results(
            db,
            [
                {**key_fields(row), "bonus_amount": amount, "calculation_status": "calculated"}
                for row, amount in to_calculate
            ],
            heartbeat,
        )
        failed_ids = {change["id"] for change in failed}
        if failed_ids:
            logger.warning("Could not save bonus for %d rows", len(failed_ids))

    results: List[BonusResult] = []
    for row, amount in to_calculate:
        if row["id"] in failed_ids:
            errors.append(
                BonusCalculationError(
                    bonus_result_id=row["id"],
                    user_name=(row.get("users") or {}).get("name"),
                    issues=[f"Calculated ({amount}) but could not be saved"],
                )
            )
            continue
        row["bonus_amount"] = amount
        row["calculation_status"] = "calculated"
        results.append(to_bonus_result(row))

    return len(results), results, errors
