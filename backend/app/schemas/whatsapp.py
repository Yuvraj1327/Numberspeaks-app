"""Pydantic models for the "WhatsApp opened" record.

The backend never sends WhatsApp messages. The app opens a wa.me link on the
admin's own device and, only once that has actually been opened, tells the
backend so it can record the fact. This is NOT a delivery receipt.
"""

from typing import Optional

from pydantic import BaseModel, Field


class WhatsAppInitiatedRequest(BaseModel):
    whatsapp_number: str = Field(..., description="The number the wa.me link was opened for.")
    message: str = Field(..., min_length=1, max_length=2000, description="The (possibly edited) text that was pre-filled.")


class WhatsAppInitiatedResponse(BaseModel):
    bonus_result_id: str
    whatsapp_status: str = "initiated"
    whatsapp_initiated_at: Optional[str] = None
    whatsapp_initiated_count: int = 0
