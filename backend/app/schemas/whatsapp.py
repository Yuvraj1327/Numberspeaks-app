"""Pydantic models for the WhatsApp send endpoint."""

from typing import List, Optional

from pydantic import BaseModel


class WhatsAppMessageResult(BaseModel):
    bonus_result_id: str
    user_id: str
    user_name: str
    whatsapp_number: Optional[str] = None
    status: str  # "sent" | "failed" | "skipped_already_sent" | "skipped_no_number" | "skipped_no_bonus"
    message: Optional[str] = None
    provider_message_id: Optional[str] = None
    error: Optional[str] = None


class WhatsAppSendSummary(BaseModel):
    report_id: str
    total_eligible: int
    sent_count: int
    failed_count: int
    skipped_count: int
    results: List[WhatsAppMessageResult]
