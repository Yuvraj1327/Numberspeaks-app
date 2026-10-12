"""Pydantic models for casino-user management and calculation history."""

from typing import List, Optional

from pydantic import BaseModel


class UserProfile(BaseModel):
    user_id: str
    name: str
    level: Optional[str] = None
    whatsapp_number: Optional[str] = None
    carry_forward_balance: Optional[float] = None  # latest balance owed/carried, if ever calculated
    created_at: Optional[str] = None


class UserUpdate(BaseModel):
    """Fields the admin can edit. Only fields that are sent change.
    An empty WhatsApp number clears it."""

    whatsapp_number: Optional[str] = None
    name: Optional[str] = None
    level: Optional[str] = None


class HistoryEntry(BaseModel):
    history_id: str
    run_id: str
    report_id: str
    report_file_name: Optional[str] = None
    calculated_at: str
    profit_loss: float
    personal_rate: float
    personal_adjustment: float
    referral_adjustment: float
    previous_balance: float
    final_balance: float
    payable_bonus: float
    carry_forward_balance: float


class UserHistory(BaseModel):
    user: UserProfile
    history: List[HistoryEntry]
