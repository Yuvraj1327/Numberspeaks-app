"""The client's arithmetic, in isolation (no database, no HTTP)."""

from decimal import Decimal

import pytest

from app.services.bonus_calculator import (
    ZERO,
    money,
    personal_adjustment,
    referral_adjustment,
    settle_balance,
    validate_rate,
)


# --- personal rule: loss -> +3%, win -> -3%, zero -> 0 ---------------------
@pytest.mark.parametrize(
    "profit_loss, expected",
    [
        (-1000, "30.00"),     # client example: loss 1,000  -> +30
        (-10000, "300.00"),   # client example: loss 10,000 -> +300
        (10000, "-300.00"),   # client example: win 10,000  -> -300
        (0, "0.00"),
        (0.0, "0.00"),
    ],
)
def test_personal_adjustment_client_examples(profit_loss, expected):
    assert personal_adjustment(profit_loss) == Decimal(expected)


def test_personal_adjustment_zero_is_not_negative_zero():
    assert str(personal_adjustment(0)) == "0.00"
    assert str(personal_adjustment(0.001)) == "0.00"  # rounds to zero, never "-0.00"


def test_rounding_is_half_up_not_floating_point():
    assert personal_adjustment(-33.35) == Decimal("1.00")   # 1.0005 -> 1.00 (half-up of 1.0005 is 1.00 at 2dp)
    assert personal_adjustment(-50) == Decimal("1.50")
    assert personal_adjustment(-16.5) == Decimal("0.50")    # 0.495 -> 0.50 half-up
    assert personal_adjustment(16.5) == Decimal("-0.50")


# --- referral rule: same shape at 10% ----------------------------------------
def test_referral_client_example():
    # referred users collectively lose 10,000 -> +1,000 at 10%
    assert referral_adjustment(-10000) == Decimal("1000.00")
    assert referral_adjustment(10000) == Decimal("-1000.00")
    assert referral_adjustment(0) == ZERO


def test_rates_are_configurable():
    assert personal_adjustment(-1000, 0.05) == Decimal("50.00")
    assert personal_adjustment(1000, 0.05) == Decimal("-50.00")
    assert referral_adjustment(-1000, 0.2) == Decimal("200.00")
    assert personal_adjustment(-1000, 0) == ZERO


@pytest.mark.parametrize("bad", [-0.01, 1.01, 3])
def test_rate_must_be_a_fraction(bad):
    with pytest.raises(ValueError):
        validate_rate(bad)
    with pytest.raises(ValueError):
        personal_adjustment(-100, bad)


# --- settlement ---------------------------------------------------------------
def test_positive_final_is_payable():
    s = settle_balance(0, 30, 0)
    assert (s.final_balance, s.payable_bonus, s.carry_forward_balance) == (Decimal("30.00"), Decimal("30.00"), ZERO)


def test_negative_final_pays_zero_and_carries_forward():
    s = settle_balance(0, -300, 0)
    assert s.payable_bonus == ZERO
    assert s.carry_forward_balance == Decimal("-300.00")
    assert s.final_balance == Decimal("-300.00")


def test_zero_final_pays_zero_and_carries_nothing():
    s = settle_balance(-30, 30, 0)
    assert s.final_balance == ZERO and s.payable_bonus == ZERO and s.carry_forward_balance == ZERO


def test_final_is_previous_plus_personal_plus_referral():
    s = settle_balance(-100, 30, 1000)
    assert s.final_balance == Decimal("930.00")
    assert s.payable_bonus == Decimal("930.00")
    assert (s.previous_balance, s.personal_adjustment, s.referral_adjustment) == (
        Decimal("-100.00"), Decimal("30.00"), Decimal("1000.00"))


def test_referral_can_offset_a_negative_personal_balance():
    s = settle_balance(0, -300, 100)
    assert s.final_balance == Decimal("-200.00") and s.payable_bonus == ZERO and s.carry_forward_balance == Decimal("-200.00")


def test_money_never_returns_negative_zero():
    assert str(money(Decimal("-0.001"))) == "0.00"
