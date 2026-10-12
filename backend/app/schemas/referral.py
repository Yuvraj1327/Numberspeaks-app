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
    calculated_at: Optional[str] = None
    created_at: Optional[str] = None


class BonusSettings(BaseModel):
    personal_rate: float = Field(..., ge=0, le=1, description="Fraction, 0.03 = 3%.")
    referral_rate: float = Field(..., ge=0, le=1, description="Fraction, 0.10 = 10%.")
    updated_at: Optional[str] = None


class BonusSettingsUpdate(BaseModel):
    personal_rate: Optional[float] = Field(None, ge=0, le=1)
    referral_rate: Optional[float] = Field(None, ge=0, le=1)
