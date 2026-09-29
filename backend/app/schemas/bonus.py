"""
Pydantic models for bonus calculation and results.

BonusResult mirrors a bonus_results row exactly (joined with the user's
name/level for readability) — the input values that went into the
calculation are returned alongside the result, never hidden or replaced.
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
        None, description="Null until calculated — never a guessed value."
    )
    calculation_status: str = Field(
        "pending",
        description="'pending' (not yet calculated), 'calculated', or 'invalid' "
        "(row failed validation and was not calculated).",
    )
    whatsapp_status: str = Field(
        "not_sent",
        description="Latest WhatsApp send attempt's outcome for this user: "
        "'not_sent' (never attempted — e.g. no bonus, no number, or not "
        "sent yet), 'sent', or 'failed'. Part of the admin results view.",
    )
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
    results: List[BonusResult]
    errors: List[BonusCalculationError]
