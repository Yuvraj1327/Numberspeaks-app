"""
Bonus calculation — the client's rules live here, and ONLY here.

This module is pure arithmetic: no Supabase, no HTTP, no I/O. Everything
else (extraction, validation, storage, the API) lives elsewhere, which is
what makes these rules easy to test exhaustively.

CLIENT RULES (confirmed in the "Complete Bonus Management" brief):

  Personal adjustment (rate: 3% by default, configurable)
      profit_loss < 0   ->  +  rate * |profit_loss|     (a loss earns a bonus)
      profit_loss > 0   ->  -  rate * profit_loss       (a win is deducted)
      profit_loss == 0  ->  0
    e.g. loss 1,000 -> +30 | loss 10,000 -> +300 | win 10,000 -> -300

  Referral adjustment (rate: 10% by default, configurable) — same shape,
  applied to the REFERRED user's profit/loss and credited to the referrer:
      referred user lost 10,000 -> +1,000 | won 10,000 -> -1,000

  Settlement (personal and referral are kept separate until here):
      final_balance = previous_carried_balance + personal + referral
      final > 0   -> payable bonus = final,  carry-forward = 0
      final < 0   -> payable bonus = 0,      carry-forward = final (negative)
      final == 0  -> payable bonus = 0,      carry-forward = 0

No other business rule is applied. Money is handled with Decimal and rounded
HALF-UP to 2 decimal places (₹ and paise) so e.g. 3% of 33.35 is 1.00, not a
binary-float surprise.
"""

from dataclasses import dataclass
from decimal import ROUND_HALF_UP, Decimal
from typing import Union

Number = Union[int, float, str, Decimal]

CENT = Decimal("0.01")
ZERO = Decimal("0.00")

# Starting values only; each admin can change them (bonus_settings table).
DEFAULT_PERSONAL_RATE = Decimal("0.03")
DEFAULT_REFERRAL_RATE = Decimal("0.10")


def to_decimal(value: Number) -> Decimal:
    """Converts via str() so a float like 0.1 becomes Decimal('0.1'), not its
    binary expansion."""
    if isinstance(value, Decimal):
        return value
    return Decimal(str(value))


def money(value: Number) -> Decimal:
    """Rounds to 2 decimal places, half-up, and never returns negative zero."""
    rounded = to_decimal(value).quantize(CENT, rounding=ROUND_HALF_UP)
    return ZERO if rounded == 0 else rounded


def validate_rate(rate: Number) -> Decimal:
    """A rate is a fraction between 0 and 1 inclusive (0.03 = 3%)."""
    value = to_decimal(rate)
    if value < 0 or value > 1:
        raise ValueError("A rate must be between 0 and 1 (for example 0.03 for 3%).")
    return value


def _adjustment(profit_loss: Number, rate: Number) -> Decimal:
    """Loss -> positive, win -> negative, zero -> 0 (see module docstring)."""
    pl = to_decimal(profit_loss)
    r = validate_rate(rate)
    if pl < 0:
        return money(-pl * r)
    if pl > 0:
        return money(-(pl * r))
    return ZERO


def personal_adjustment(profit_loss: Number, rate: Number = DEFAULT_PERSONAL_RATE) -> Decimal:
    """The user's own weekly bonus (+) or deduction (-)."""
    return _adjustment(profit_loss, rate)


def referral_adjustment(referred_profit_loss: Number, rate: Number = DEFAULT_REFERRAL_RATE) -> Decimal:
    """One referred user's contribution to their referrer: + if they lost,
    - if they won."""
    return _adjustment(referred_profit_loss, rate)


@dataclass(frozen=True)
class Settlement:
    """The full, separately-visible breakdown for one user in one period."""

    previous_balance: Decimal
    personal_adjustment: Decimal
    referral_adjustment: Decimal
    final_balance: Decimal
    payable_bonus: Decimal
    carry_forward_balance: Decimal


def settle_balance(
    previous_balance: Number,
    personal: Number,
    referral: Number,
) -> Settlement:
    """final = previous + personal + referral; positive -> payable,
    negative -> carried forward, zero -> nothing."""
    prev = money(previous_balance)
    pers = money(personal)
    ref = money(referral)
    final = money(prev + pers + ref)

    if final > 0:
        payable, carry = final, ZERO
    elif final < 0:
        payable, carry = ZERO, final
    else:
        payable, carry = ZERO, ZERO

    return Settlement(
        previous_balance=prev,
        personal_adjustment=pers,
        referral_adjustment=ref,
        final_balance=final,
        payable_bonus=payable,
        carry_forward_balance=carry,
    )
