"""
Bonus calculation orchestration.

This is the glue between validation (Step 4), the pure formula
(bonus_calculator.py), and Supabase — it does not contain any formula
logic itself, and it does not talk to Supabase for anything beyond saving
the result of a calculation that already happened.

Each row is validated, calculated, and saved independently: one bad or
failed row is recorded as an error and skipped, it never stops the rest
of the report from being calculated.
"""

import logging
from typing import List, Tuple

from supabase import Client

from app.schemas.bonus import BonusCalculationError, BonusResult
from app.schemas.validation import InvalidRecord
from app.services.bonus_calculator import BonusFormulaNotConfiguredError, BonusInput, calculate_bonus, is_formula_configured
from app.services.reports_service import bonus_result_row_to_raw, default_row_reference, to_bonus_result, update_bonus_amount
from app.services.validation import validate_record

logger = logging.getLogger("numberspeaks")


def run_bonus_calculation(
    db: Client, rows: List[dict]
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

    results: List[BonusResult] = []
    errors: List[BonusCalculationError] = []
    calculated = 0

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
            logger.warning("Bonus calculation failed for %r (row %s): %s", user_name, bonus_result_id, exc)
            errors.append(
                BonusCalculationError(
                    bonus_result_id=bonus_result_id,
                    user_name=user_name,
                    issues=[f"Calculation failed: {exc}"],
                )
            )
            continue

        try:
            update_bonus_amount(db, bonus_result_id, amount)
        except Exception as exc:  # noqa: BLE001
            logger.warning("Could not save bonus for %r (row %s): %s", user_name, bonus_result_id, exc)
            errors.append(
                BonusCalculationError(
                    bonus_result_id=bonus_result_id,
                    user_name=user_name,
                    issues=[f"Calculated ({amount}) but could not be saved: {exc}"],
                )
            )
            continue

        calculated += 1
        row["bonus_amount"] = amount
        results.append(to_bonus_result(row))

    return calculated, results, errors
