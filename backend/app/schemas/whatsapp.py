"""Pydantic models for sending bonus messages through the No1API integration."""

from typing import List, Optional

from pydantic import BaseModel, Field


class WhatsAppSendRequest(BaseModel):
    # The recipient is NOT taken from the request: the server sends to the
    # number saved for the user, so a client cannot redirect a message.
    message: str = Field(..., min_length=1, max_length=1000, description="The (possibly edited) text to send.")


class WhatsAppSendResponse(BaseModel):
    bonus_result_id: str
    send_status: str = Field(..., description="'pending', 'sending', 'sent', 'failed' or 'unknown'.")
    send_error: Optional[str] = None
    sent_at: Optional[str] = None


class BulkItem(BaseModel):
    bonus_result_id: str
    message: str = Field(..., min_length=1, max_length=1000)


class WhatsAppBulkRequest(BaseModel):
    items: List[BulkItem] = Field(..., min_length=1)
    confirmed: bool = Field(..., description="Must be true: the admin reviewed and confirmed these messages.")


class BulkSkipped(BaseModel):
    bonus_result_id: str
    user_name: Optional[str] = None
    reason: str


class BulkItemStatus(BaseModel):
    bonus_result_id: str
    user_name: Optional[str] = None
    send_status: str
    send_error: Optional[str] = None


class WhatsAppBulkProgress(BaseModel):
    batch_id: str
    status: str = Field(..., description="'running', 'completed' or 'interrupted' (the server stopped mid-run).")
    total_selected: int
    queued: int
    skipped: List[BulkSkipped]
    sent: int = 0
    failed: int = 0
    unknown: int = 0
    pending: int = 0
    items: List[BulkItemStatus] = []


class WhatsAppTestRequest(BaseModel):
    whatsapp_number: str
    message: str = Field(..., min_length=1, max_length=1000)
    authorized: bool = Field(..., description="Admin confirms this is a number they are authorized to message.")


class WhatsAppTestResponse(BaseModel):
    status: str
    error: Optional[str] = None


class WhatsAppTestStatus(BaseModel):
    tested: bool
    provider_available: bool
