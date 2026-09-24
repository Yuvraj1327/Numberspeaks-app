"""
Bonus calculation — the client's formula lives here, and ONLY here.

This module is deliberately isolated from everything else (extraction,
validation, Supabase, the API layer) so that dropping in the real formula
later never requires touching any other file.

STATUS: the client has not provided the bonus formula yet. calculate_bonus()
below intentionally raises BonusFormulaNotConfiguredError instead of
guessing — no placeholder math, no invented percentages, nothing. Every
other piece of Steps 5-6 (the API, the save-to-Supabase logic, the results
endpoints) is fully built and wired to this function; the moment the real
formula is implemented here, the whole pipeline works end to end with no
other code changes.
"""

from dataclasses import dataclass
from typing import Optional


class BonusFormulaNotConfiguredError(Exception):
    """Raised by calculate_bonus() until the client's real formula is implemented."""


@dataclass
class BonusInput:
    """Exactly the fields the client's report provides for one user, and
    nothing else — this is the complete input available to the formula."""

    user_name: str
    level: Optional[str]
    casino_pts: float
    sport_pts: float
    third_party_pts: float
    profit_loss: float
    ptype: Optional[str]


def is_formula_configured() -> bool:
    """
    The rest of the app checks this before attempting a calculation, so a
    missing formula fails with one clear message instead of raising the
    same exception once per user in a loop.

    Flip this to True in the same change that implements calculate_bonus().
    """
    return False


def calculate_bonus(data: BonusInput) -> float:
    """
    ============================================================================
    CLIENT BONUS FORMULA — NOT YET PROVIDED. DO NOT GUESS AT ONE.
    ============================================================================
    Replace the body of this function with the client's exact bonus
    formula once they provide it. Nothing in this file should be
    invented — if a rule isn't confirmed by the client, it doesn't belong
    here.

    Available inputs (one user, one report):
        data.user_name        str             e.g. "Rahul Sharma"
        data.level             str | None      e.g. "Master", "Super Master"
        data.casino_pts        float           can be negative, zero, or positive
        data.sport_pts         float           can be negative, zero, or positive
        data.third_party_pts   float           can be negative, zero, or positive
        data.profit_loss       float           can be negative, zero, or positive
        data.ptype              str | None      e.g. "User", "Admin"

    Must return:
        float — the bonus amount for this user. Return 0.0 for "no bonus",
        never None (None means "not yet calculated" elsewhere in this app).

    Once implemented:
        1. Remove the `raise` below and the docstring's warning banner.
        2. Change is_formula_configured() above to return True.
        3. If the formula differs by `level` or `ptype`, branch on those
           fields explicitly here — don't scatter formula logic elsewhere.
    ============================================================================
    """
    raise BonusFormulaNotConfiguredError(
        "No bonus formula has been configured yet. Implement calculate_bonus() "
        "in app/services/bonus_calculator.py with the client's exact formula, "
        "then set is_formula_configured() in the same file to return True."
    )
