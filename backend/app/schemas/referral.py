"""Pydantic models for referral entries and bonus-rate settings."""

from typing import Optional

from pydantic import BaseModel, Field


class ReferralCreate(BaseModel):
    """Admin links a referred user to their referrer for one period (report).

    The ids are the casino users' ids (from the results table). Which admin
    owns the entry is never taken from the request — it comes from the
    verified login.
    """

    referrer_user_id: str
    referred_user_id: str
    rate: Optional[float] = Field(
        None,
        ge=0,
        le=1,
        description="Fraction, e.g. 0.10 for 10%. Omit to use your current referral rate.",
    )
    amount: Optional[float] = Field(
        None,
        description="Referred user's profit/loss for the period (loss negative, win positive). "
        "Omit to use their profit/loss from the period's report.",
    )
    note: Optional[str] = Field(None, max_length=300)


class ReferralUpdate(BaseModel):
    rate: Optional[float] = Field(None, ge=0, le=1)
    amount: Optional[float] = Field(None, description="Manual profit/loss override.")
    clear_amount: bool = Field(False, description="Go back to the report's own profit/loss.")
    note: Optional[str] = Field(None, max_length=300)


class LedgerCreate(ReferralCreate):
    report_id: str = Field(..., description="The weekly report (period) this activity belongs to.")


class ReferralEntry(BaseModel):
    entry_id: str
    report_id: str
    referrer_user_id: str
    referrer_name: Optional[str] = None
    referred_user_id: str
    referred_name: Optional[str] = None
    rate: float
    amount: Optional[float] = Field(None, description="Referred user's profit/loss for the period, set on calculation.")
    adjustment: Optional[float] = Field(None, description="+ if the referred user lost, - if they won; set on calculation.")
    amount_source: str = Field("report", description="'report' or 'manual'.")
    note: Optional[str] = None
    period_start: Optional[str] = None
    period_end: Optional[str] = None
    calculated_at: Optional[str] = None
    created_at: Optional[str] = None


class ReferrerIn(BaseModel):
    user_id: str
    display_name: Optional[str] = Field(None, max_length=120)
    notes: Optional[str] = Field(None, max_length=500)
    default_rate: Optional[float] = Field(None, ge=0, le=1)
    is_active: bool = True


class ReferrerUpdate(BaseModel):
    display_name: Optional[str] = Field(None, max_length=120)
    notes: Optional[str] = Field(None, max_length=500)
    default_rate: Optional[float] = Field(None, ge=0, le=1)
    clear_default_rate: bool = False
    is_active: Optional[bool] = None


class Referrer(BaseModel):
    referrer_id: str
    user_id: str
    user_name: Optional[str] = None
    display_name: Optional[str] = None
    notes: Optional[str] = None
    default_rate: Optional[float] = None
    is_active: bool = True
    referred_count: int = 0
    total_adjustment: float = 0.0


class BonusSettings(BaseModel):
    personal_rate: float = Field(..., ge=0, le=1, description="Fraction, 0.03 = 3%.")
    referral_rate: float = Field(..., ge=0, le=1, description="Fraction, 0.10 = 10%.")
    whatsapp_template: Optional[str] = Field(None, description="Message template with {placeholders}.")
    updated_at: Optional[str] = None


class BonusSettingsUpdate(BaseModel):
    personal_rate: Optional[float] = Field(None, ge=0, le=1)
    referral_rate: Optional[float] = Field(None, ge=0, le=1)
    whatsapp_template: Optional[str] = Field(None, max_length=1500)
