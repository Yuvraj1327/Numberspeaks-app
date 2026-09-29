"""
WhatsApp provider integration — Meta WhatsApp Cloud API (the default; see
app/core/config.py for why). This is the ONLY file that knows how to
actually talk to a WhatsApp provider. Swapping providers later (Twilio,
Gupshup, etc.) means rewriting send_whatsapp_message() here — nothing else
in the app needs to change, since every caller only sees WhatsAppSendResult.

send_whatsapp_message() never raises for an expected failure (bad number,
provider error, network issue) — it always returns a result, so a caller
sending to many users in a loop doesn't need a try/except per call.
"""

import logging
import re
from dataclasses import dataclass
from typing import Optional

import httpx

from app.core.config import get_settings

logger = logging.getLogger("numberspeaks")


class WhatsAppNotConfiguredError(Exception):
    """Raised when WHATSAPP_API_KEY / WHATSAPP_PHONE_NUMBER_ID are missing."""


@dataclass
class WhatsAppSendResult:
    success: bool
    provider_message_id: Optional[str] = None
    error: Optional[str] = None


def _normalize_number(raw_number: str) -> str:
    """Meta's API expects digits only (country code + number, no '+',
    spaces, or punctuation)."""
    return re.sub(r"[^\d]", "", raw_number or "")


def send_whatsapp_message(to_number: str, message: str) -> WhatsAppSendResult:
    settings = get_settings()

    if not settings.has_whatsapp_config:
        raise WhatsAppNotConfiguredError(
            "WHATSAPP_API_KEY and WHATSAPP_PHONE_NUMBER_ID must be set in the environment (.env)."
        )

    number = _normalize_number(to_number)
    if not number:
        return WhatsAppSendResult(success=False, error=f"Invalid WhatsApp number: {to_number!r}")

    url = f"{settings.WHATSAPP_API_BASE_URL.rstrip('/')}/{settings.WHATSAPP_PHONE_NUMBER_ID}/messages"
    payload = {
        "messaging_product": "whatsapp",
        "to": number,
        "type": "text",
        "text": {"body": message},
    }
    headers = {
        "Authorization": f"Bearer {settings.WHATSAPP_API_KEY}",
        "Content-Type": "application/json",
    }

    try:
        response = httpx.post(url, json=payload, headers=headers, timeout=15.0)
    except httpx.RequestError as exc:
        logger.warning("WhatsApp request failed: %s", exc)
        return WhatsAppSendResult(success=False, error=f"Network error contacting WhatsApp API: {exc}")

    try:
        body = response.json()
    except ValueError:
        body = {}

    if response.status_code >= 400:
        error_message = (body.get("error") or {}).get("message") or response.text or "Unknown error"
        logger.warning("WhatsApp API returned %s: %s", response.status_code, error_message)
        return WhatsAppSendResult(success=False, error=f"WhatsApp API error ({response.status_code}): {error_message}")

    message_id = None
    messages = body.get("messages") or []
    if messages:
        message_id = messages[0].get("id")

    return WhatsAppSendResult(success=True, provider_message_id=message_id)
