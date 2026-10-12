"""
Pydantic models for bonus calculation and results.

BonusResult mirrors a bonus_results row (joined with the user's
name/level/WhatsApp number) — the input values that went into the
calculation are returned alongside the result, never hidden or replaced.

`bonus_amount` is the FINAL PAYABLE bonus (never negative). It is kept
under that name so every existing consumer keeps working; `payable_bonus`
carries the same number explicitly. The rest of the breakdown (personal
adjustment, referral adjustment, previous balance, final balance, carry
forward) is returned separately so personal and referral figures are never
blended together.
"""

from typing import List, Optional

from pydantic import BaseModel, Field


class BonusResult(BaseModel):
    bonus_result_id: str
    report_id: str
    user_id: str
    user_name: str
    whatsapp_number: Optional[str] = None
    level: Optional[str] = None
    casino_pts: float
    sport_pts: float
    third_party_pts: float
    profit_loss: float
    ptype: Optional[str] = None

    bonus_amount: Optional[float] = Field(
        None,
        description="The final PAYABLE bonus (>= 0). Null until calculated — never a guessed value.",
    )
    calculation_status: str = Field(
        "pending",
        description="'pending' (not yet calculated), 'calculated', or 'invalid' "
        "(row failed validation and was not calculated).",
    )

    # --- Calculation breakdown (all null until calculated) ---------------
    personal_rate_used: Optional[float] = Field(None, description="The personal rate applied, e.g. 0.03.")
    personal_adjustment: Optional[float] = Field(
        None, description="+3% of a loss, -3% of a win, 0 for zero (rate configurable)."
    )
    referral_adjustment: Optional[float] = Field(
        None, description="Sum of this user's referral entries for the period (kept separate from personal)."
    )
    previous_balance: Optional[float] = Field(None, description="Carried-forward balance from the previous period.")
    final_balance: Optional[float] = Field(None, description="previous + personal + referral.")
    payable_bonus: Optional[float] = Field(None, description="final_balance if positive, else 0.")
    carry_forward_balance: Optional[float] = Field(
        None, description="final_balance if negative (carried to the next period), else 0."
    )
    calculated_at: Optional[str] = None

    # --- WhatsApp (the app only OPENS wa.me; nothing is sent via an API) --
    whatsapp_status: str = Field(
        "not_sent",
        description="'not_sent' or 'initiated' (the admin opened WhatsApp with the message "
        "pre-filled). It is NEVER 'sent'/'delivered' — the backend cannot know that.",
    )
    whatsapp_initiated_at: Optional[str] = None
    whatsapp_initiated_count: int = 0

    created_at: Optional[str] = None


class BonusCalculationError(BaseModel):
    bonus_result_id: Optional[str] = None
    user_name: Optional[str] = None
    issues: List[str]


class BonusCalculationSummary(BaseModel):
    report_id: str
    status: str
    total_input_records: int
    calculated_count: int
    failed_count: int
    total_payable: float = 0.0
    payable_user_count: int = 0
    results: List[BonusResult]
    errors: List[BonusCalculationError]


class RowCorrection(BaseModel):
    """Admin corrections to one extracted row, applied before the bonus is
    (re)calculated. Every field is optional; only the ones sent are changed.
    Numeric fields accept numbers only (no text) so a typo can't slip in."""

    user_name: Optional[str] = Field(None, description="User ID / Name as it should read.")
    level: Optional[str] = None
    casino_pts: Optional[float] = None
    sport_pts: Optional[float] = None
    third_party_pts: Optional[float] = None
    profit_loss: Optional[float] = None
    ptype: Optional[str] = None
    whatsapp_number: Optional[str] = None
