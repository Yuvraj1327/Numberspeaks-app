"""
The ONLY module that talks to No1API. Server-side only: the access token never
reaches the Flutter app, logs, error messages or the database.

Request format. No1API's dashboard (Channel -> API Details) exposes an "API URL"
ending in /api/meta, an "API Version" (v19.0), a "Phone Number ID" and a "WABA
ID" — i.e. Meta's WhatsApp Cloud API contract behind a proxy. This client uses
that contract:

    POST {NO1API_BASE_URL}/{NO1API_API_VERSION}/{NO1API_PHONE_NUMBER_ID}/messages
    Authorization: Bearer {NO1API_API_KEY}
    {"messaging_product": "whatsapp", "to": "<digits>", "type": "text",
     "text": {"body": "<message>"}}
    -> 200 {"messages": [{"id": "wamid..."}]}  on acceptance
    -> 4xx {"error": {"message": ..., "code": ...}}  on rejection

This is inferred from the dashboard fields and Meta's published format, not from
No1API-specific documentation. The first message to an authorized test number
(the bulk dialog forces one) is what proves it works; if No1API differs, only
`send_text` needs changing.

Important WhatsApp rule: a free-text message is only deliverable when the user
wrote to this number in the last 24 hours. Otherwise the provider rejects it
(error 131047) and an approved message template is needed.

Contract for `send_text`:
  * return SendOutcome only when the provider accepted the message ("sent" means
    provider-accepted — not delivered or read; no delivery receipts are used);
  * raise ProviderSendError(safe_message) for a rejection or when the request
    provably never left (connection refused);
  * raise ProviderOutcomeUnknown when it may have been processed but no answer
    arrived (timeout, dropped connection, 5xx);
  * messages shown to the admin never contain the token or the message text.
"""

import re
from dataclasses import dataclass
from typing import Optional
from urllib.parse import urlsplit, urlunsplit

import httpx

from app.core.config import get_settings

SPEC_IMPLEMENTED = True
TIMEOUT = httpx.Timeout(connect=10.0, read=30.0, write=10.0, pool=10.0)

# Meta error codes with a more useful explanation than the raw text.
_KNOWN_ERRORS = {
    131047: "WhatsApp only allows free-text messages within 24 hours of the user's last message to this "
    "number. An approved message template is needed for this user.",
    131030: "This number is not on the allowed recipient list for this WhatsApp account.",
    131026: "This number could not receive the message (not on WhatsApp or blocked).",
    190: "The No1API access token is invalid or expired.",
}


class ProviderNotConfigured(Exception):
    """The No1API integration cannot be used (settings missing)."""


class ProviderSendError(Exception):
    """The provider did not accept the message. str(exc) is safe to show the admin."""


class ProviderOutcomeUnknown(Exception):
    """The request may have reached the provider but no answer was received
    (timeout, connection dropped, 5xx). The message may or may not have been
    sent; it is recorded as 'unknown', never as sent or failed."""


@dataclass(frozen=True)
class SendOutcome:
    provider_message_id: Optional[str] = None


def is_available() -> bool:
    s = get_settings()
    return SPEC_IMPLEMENTED and all(
        (s.NO1API_BASE_URL, s.NO1API_API_KEY, s.NO1API_API_VERSION, s.NO1API_PHONE_NUMBER_ID)
    )


def _messages_url() -> str:
    s = get_settings()
    parts = urlsplit(s.NO1API_BASE_URL.strip())
    path = re.sub(r"/{2,}", "/", parts.path).rstrip("/")  # the dashboard shows "//api/meta"
    path = f"{path}/{s.NO1API_API_VERSION.strip().strip('/')}/{s.NO1API_PHONE_NUMBER_ID.strip()}/messages"
    return urlunsplit((parts.scheme, parts.netloc, path, "", ""))


def _digits(number: str) -> str:
    return re.sub(r"\D", "", number)


def send_text(number: str, message: str) -> SendOutcome:
    if not is_available():
        raise ProviderNotConfigured("The No1API integration is not configured on the server.")
    s = get_settings()
    body = {
        "messaging_product": "whatsapp",
        "recipient_type": "individual",
        "to": _digits(number),
        "type": "text",
        "text": {"preview_url": False, "body": message},
    }
    try:
        response = httpx.post(
            _messages_url(),
            json=body,
            headers={"Authorization": f"Bearer {s.NO1API_API_KEY.strip()}"},
            timeout=TIMEOUT,
        )
    except httpx.ConnectError as exc:
        raise ProviderSendError("Could not reach No1API. Nothing was sent.") from None
    except (httpx.TimeoutException, httpx.TransportError) as exc:
        raise ProviderOutcomeUnknown() from None

    try:
        data = response.json()
    except ValueError:
        data = {}

    if response.status_code == 200:
        messages = data.get("messages") if isinstance(data, dict) else None
        if isinstance(messages, list) and messages and isinstance(messages[0], dict) and messages[0].get("id"):
            return SendOutcome(provider_message_id=str(messages[0]["id"]))
        # 200 without a message id: acceptance is not proven.
        raise ProviderOutcomeUnknown()

    if response.status_code >= 500:
        raise ProviderOutcomeUnknown()

    error = data.get("error") if isinstance(data, dict) else None
    code = error.get("code") if isinstance(error, dict) else None
    if code in _KNOWN_ERRORS:
        raise ProviderSendError(_KNOWN_ERRORS[code])
    if response.status_code in (401, 403):
        raise ProviderSendError("No1API rejected the credentials (HTTP %d)." % response.status_code)
    detail = str(error.get("message"))[:200] if isinstance(error, dict) and error.get("message") else ""
    raise ProviderSendError(f"No1API rejected the message (HTTP {response.status_code}). {detail}".strip())
