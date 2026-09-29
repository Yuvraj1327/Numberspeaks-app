"""
Bonus calculation — the client's formula lives here, and ONLY here.

This module is deliberately isolated from everything else (extraction,
validation, Supabase, the API layer), so nothing outside this file needed
to change when the real formula below was implemented.

CLIENT FORMULA (confirmed):
    Only a LOSS earns a bonus. If profit_loss is negative:
        bonus = abs(profit_loss) * 3%
    If profit_loss is zero or positive: bonus = 0.

    Examples given by the client:
        -1000 -> 30
        -2500 -> 75
        -5000 -> 150
"""

from dataclasses import dataclass
from typing import Optional


BONUS_RATE = 0.03  # 3%, per the client's confirmed formula


class BonusFormulaNotConfiguredError(Exception):
    """Raised by calculate_bonus() if the formula is ever disabled again via
    is_formula_configured(); kept so callers don't need to change if that
    happens."""


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
    """
    return True


def calculate_bonus(data: BonusInput) -> float:
    """
    Client's confirmed formula — only a loss earns a bonus:
        profit_loss < 0  ->  bonus = abs(profit_loss) * 3%
        profit_loss >= 0 ->  bonus = 0

    `level`, `casino_pts`, `sport_pts`, `third_party_pts` and `ptype` are
    not part of this formula — the client's rule is based on profit_loss
    alone, so nothing else on BonusInput is used here. Always returns a
    float (0.0 for "no bonus"), never None.
    """
    if data.profit_loss < 0:
        return round(abs(data.profit_loss) * BONUS_RATE, 2)
    return 0.0
