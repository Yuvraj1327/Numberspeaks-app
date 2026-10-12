"""
Bonus calculation orchestration.

This is the glue between validation (Step 4), the pure rules
(bonus_calculator.py) and Supabase — it contains no business rule itself.

For one report it:
  1. validates every row (a bad row is recorded as an error and skipped; it
     never stops the rest of the report);
  2. adds up each referrer's referral adjustment from the report's referral
     entries, separately from personal bonuses;
  3. looks up each user's carried-forward balance from their most recent
     earlier calculated period;
  4. settles each user:  final = previous + personal + referral
        final > 0  -> payable bonus
        final <= 0 -> payable 0, a negative final carries forward;
  5. saves the full breakdown on the row, fills in each referral entry's
     amount/adjustment, and appends one calculation_history line per user.

Recalculating the same report gives the same numbers (it only reads EARLIER
reports for previous balances) and adds a new history run each time.
"""

import logging
from datetime import datetime, timezone
from decimal import Decimal
from typing import Dict, List, Tuple
from uuid import uuid4

from supabase import Client

from app.schemas.bonus import BonusCalculationError, BonusResult
from app.schemas.report import ExtractedRecord
from app.schemas.validation import InvalidRecord
from app.services.bonus_calculator import (
    ZERO,
    money,
    personal_adjustment,
    referral_adjustment,
    settle_balance,
    to_decimal,
)
from app.services.referral_service import fetch_entry_rows
from app.services.reports_service import (
    INSERT_CHUNK,
    bonus_result_row_to_raw,
    chunked,
    default_row_reference,
    to_bonus_result,
    update_calculation_status,
)
from app.services.settings_service import get_bonus_settings
from app.services.users_service import previous_balances
from app.services.validation import validate_record

logger = logging.getLogger("numberspeaks")


def run_bonus_calculation(
    db: Client,
    owner_id: str,
    report: dict,
    rows: List[dict],
) -> Tuple[int, List[BonusResult], List[BonusCalculationError]]:
    """
    Validates, calculates and saves a bonus breakdown for each row of
    `report`. Returns (calculated_count, results, errors).
    """
    report_id = report["id"]
    results: List[BonusResult] = []
    errors: List[BonusCalculationError] = []

    # --- 1. validate every row ------------------------------------------------
    valid: List[Tuple[dict, ExtractedRecord]] = []
    for row in rows:
        user = row.get("users") or {}
        user_name = user.get("name")
        bonus_result_id = row.get("id")

        raw = bonus_result_row_to_raw(row)
        outcome = validate_record(raw, default_row_reference(raw, 0))

        if outcome is None:
            continue  # blank/leftover-header row — ignored, consistent with Step 4

        if isinstance(outcome, InvalidRecord):
            errors.append(
                BonusCalculationError(bonus_result_id=bonus_result_id, user_name=user_name, issues=outcome.issues)
            )
            if bonus_result_id:
                try:
                    update_calculation_status(db, owner_id, bonus_result_id, "invalid")
                except Exception as exc:  # noqa: BLE001
                    logger.warning("Could not persist 'invalid' status for row %s: %s", bonus_result_id, exc)
            continue

        valid.append((row, outcome))

    if not valid:
        return 0, results, errors

    # --- 2. rates, referrals, previous balances --------------------------------
    settings = get_bonus_settings(db, owner_id)
    personal_rate = to_decimal(settings.personal_rate)

    profit_loss_by_user: Dict[str, Decimal] = {
        row["user_id"]: to_decimal(record.profit_loss) for row, record in valid
    }
    names_by_user: Dict[str, str] = {
        row["user_id"]: (row.get("users") or {}).get("name", "") for row, _ in valid
    }

    referral_by_referrer: Dict[str, Decimal] = {}
    entry_updates: List[Tuple[str, Decimal, Decimal]] = []
    for entry in fetch_entry_rows(db, owner_id, report_id):
        referrer_id = entry["referrer_user_id"]
        referred_id = entry["referred_user_id"]
        if referrer_id not in profit_loss_by_user or referred_id not in profit_loss_by_user:
            errors.append(
                BonusCalculationError(
                    bonus_result_id=None,
                    user_name=names_by_user.get(referrer_id),
                    issues=[
                        "A referral entry was skipped because the referrer or the referred user "
                        "does not have a valid row in this report."
                    ],
                )
            )
            continue
        referred_pl = profit_loss_by_user[referred_id]
        adjustment = referral_adjustment(referred_pl, entry["rate"])
        referral_by_referrer[referrer_id] = money(referral_by_referrer.get(referrer_id, ZERO) + adjustment)
        entry_updates.append((entry["id"], referred_pl, adjustment))

    previous = previous_balances(
        db,
        owner_id,
        before_uploaded_at=report.get("uploaded_at"),
        needed_user_ids=set(profit_loss_by_user),
    )

    # --- 3. settle + save each user ----------------------------------------------
    run_id = str(uuid4())
    now = datetime.now(timezone.utc).isoformat()
    history_rows: List[dict] = []
    calculated = 0

    for row, record in valid:
        user_id = row["user_id"]
        bonus_result_id = row["id"]
        user_name = (row.get("users") or {}).get("name")

        personal = personal_adjustment(record.profit_loss, personal_rate)
        settlement = settle_balance(
            previous.get(user_id, ZERO),
            personal,
            referral_by_referrer.get(user_id, ZERO),
        )

        update = {
            # bonus_amount is what the rest of the system already reads: it
            # now means "the final PAYABLE bonus" (never negative).
            "bonus_amount": float(settlement.payable_bonus),
            "payable_bonus": float(settlement.payable_bonus),
            "personal_rate_used": float(personal_rate),
            "personal_adjustment": float(settlement.personal_adjustment),
            "referral_adjustment": float(settlement.referral_adjustment),
            "previous_balance": float(settlement.previous_balance),
            "final_balance": float(settlement.final_balance),
            "carry_forward_balance": float(settlement.carry_forward_balance),
            "calculation_status": "calculated",
            "calculated_at": now,
        }

        try:
            db.table("bonus_results").update(update).eq("owner_id", owner_id).eq("id", bonus_result_id).execute()
        except Exception as exc:  # noqa: BLE001
            logger.warning("Could not save bonus for %r (row %s): %s", user_name, bonus_result_id, exc)
            errors.append(
                BonusCalculationError(
                    bonus_result_id=bonus_result_id,
                    user_name=user_name,
                    issues=[f"Calculated but could not be saved: {exc}"],
                )
            )
            continue

        calculated += 1
        row.update(update)
        results.append(to_bonus_result(row))
        history_rows.append(
            {
                "owner_id": owner_id,
                "run_id": run_id,
                "report_id": report_id,
                "bonus_result_id": bonus_result_id,
                "user_id": user_id,
                "profit_loss": float(to_decimal(record.profit_loss)),
                "personal_rate": float(personal_rate),
                "personal_adjustment": float(settlement.personal_adjustment),
                "referral_adjustment": float(settlement.referral_adjustment),
                "previous_balance": float(settlement.previous_balance),
                "final_balance": float(settlement.final_balance),
                "payable_bonus": float(settlement.payable_bonus),
                "carry_forward_balance": float(settlement.carry_forward_balance),
                "calculated_at": now,
            }
        )

    # --- 4. referral entries + history (best effort, reported if they fail) ----------
    for entry_id, amount, adjustment in entry_updates:
        try:
            db.table("referral_entries").update(
                {"amount": float(amount), "adjustment": float(adjustment), "calculated_at": now}
            ).eq("owner_id", owner_id).eq("id", entry_id).execute()
        except Exception as exc:  # noqa: BLE001
            logger.warning("Could not save referral entry %s: %s", entry_id, exc)
            errors.append(
                BonusCalculationError(
                    bonus_result_id=None,
                    user_name=None,
                    issues=[f"A referral entry was applied but its amount could not be saved: {exc}"],
                )
            )

    for chunk in chunked(history_rows, INSERT_CHUNK):
        try:
            db.table("calculation_history").insert(chunk).execute()
        except Exception as exc:  # noqa: BLE001
            logger.warning("Could not save calculation history: %s", exc)
            errors.append(
                BonusCalculationError(
                    bonus_result_id=None,
                    user_name=None,
                    issues=[f"Bonuses were saved but part of the calculation history could not be recorded: {exc}"],
                )
            )

    return calculated, results, errors
