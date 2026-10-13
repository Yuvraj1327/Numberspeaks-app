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
    -> 200 {"messaging_channel": "whatsapp",
            "message": {"queue_id": "...", "message_status": "queued"}}   (observed in production)
    -> 4xx {"error": {"message": ..., "code": ...}}  on rejection

The request is inferred from the dashboard fields and Meta's published format;
the 200 answer above is what No1API really returned. No No1API documentation is
available to this project, so there is NO delivery-status endpoint or webhook
here: a queued message stays 'queued' and is never shown as sent or delivered
until a documented source for that exists.

Important WhatsApp rule: a free-text message is only deliverable when the user
wrote to this number in the last 24 hours. Otherwise the provider rejects it
(error 131047) and an approved message template is needed.

Contract for `send_text`:
  * return SendOutcome only when the provider accepted the message: status
    'queued' (accepted into No1API's queue; neither sent nor delivered). No
    delivery receipts are used, so 'delivered' is never produced;
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
    """The request may have reached the provider but acceptance was not proven
    (timeout, dropped connection, 5xx, or a 200 without a message id). The
    message may or may not have been sent; it is recorded as 'unknown', never
    as sent or failed. str(exc), when set, says what the provider answered and
    is safe to store and show (the token is redacted)."""


@dataclass(frozen=True)
class SendOutcome:
    """What the provider confirmed. `status` is OUR status for it: 'queued' (No1API
    accepted it into its queue) or 'sent'. Nothing here claims delivery."""

    provider_message_id: Optional[str] = None
    status: str = "queued"
    provider_status: Optional[str] = None


def is_available() -> bool:
    s = get_settings()
    return SPEC_IMPLEMENTED and all(
        (s.NO1API_BASE_URL, s.no1api_token, s.NO1API_API_VERSION, s.NO1API_PHONE_NUMBER_ID)
    )


def _messages_url() -> str:
    s = get_settings()
    parts = urlsplit(s.NO1API_BASE_URL.strip())
    path = re.sub(r"/{2,}", "/", parts.path).rstrip("/")  # the dashboard shows "//api/meta"
    path = f"{path}/{s.NO1API_API_VERSION.strip().strip('/')}/{s.NO1API_PHONE_NUMBER_ID.strip()}/messages"
    return urlunsplit((parts.scheme, parts.netloc, path, "", ""))


def _describe(response: "httpx.Response") -> str:
    """What the provider answered, for diagnosing 'unknown' outcomes. Never
    contains the access token."""
    token = get_settings().no1api_token
    text = response.text or ""
    if token:
        text = text.replace(token, "[redacted]")
    text = re.sub(r"\s+", " ", text).strip()[:300] or "(empty body)"
    return f"No1API answered HTTP {response.status_code}: {text}"


def _digits(number: str) -> str:
    return re.sub(r"\D", "", number)


def _parse_accepted(data, response: "httpx.Response") -> SendOutcome:
    """Reads a 200 answer. Observed No1API answer (production logs):
        {"messaging_channel": "whatsapp", "message": {"queue_id": "...", "message_status": "queued"}}
    'queued' is the only provider status handled: it is stored as our 'queued'
    (accepted into No1API's queue; NOT sent, NOT delivered). The Meta-style
    {"messages": [{"id": ...}]} answer is also accepted. Anything else is
    'unknown' (with the answer recorded), never assumed to be a success."""
    if isinstance(data, dict):
        message = data.get("message")
        if isinstance(message, dict) and message.get("queue_id"):
            provider_status = str(message.get("message_status") or "").strip().lower()
            if provider_status == "queued":
                return SendOutcome(
                    provider_message_id=str(message["queue_id"]), status="queued", provider_status=provider_status
                )
            raise ProviderOutcomeUnknown(_describe(response) + f" (unhandled message_status {provider_status!r})")
        messages = data.get("messages")
        if isinstance(messages, list) and messages and isinstance(messages[0], dict) and messages[0].get("id"):
            return SendOutcome(provider_message_id=str(messages[0]["id"]), status="sent", provider_status="accepted")
    raise ProviderOutcomeUnknown(_describe(response) + " (no queue id or message id found)")


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
            headers={"Authorization": f"Bearer {s.no1api_token}"},
            timeout=TIMEOUT,
        )
    except httpx.ConnectError:
        raise ProviderSendError("Could not reach No1API. Nothing was sent.") from None
    except (httpx.TimeoutException, httpx.TransportError) as exc:
        raise ProviderOutcomeUnknown(
            f"No answer from No1API ({type(exc).__name__}); the message may or may not have been sent."
        ) from None

    try:
        data = response.json()
    except ValueError:
        data = {}

    if response.status_code == 200:
        return _parse_accepted(data, response)

    if response.status_code >= 500:
        raise ProviderOutcomeUnknown(_describe(response))

    error = data.get("error") if isinstance(data, dict) else None
    code = error.get("code") if isinstance(error, dict) else None
    if code in _KNOWN_ERRORS:
        raise ProviderSendError(_KNOWN_ERRORS[code])
    if response.status_code in (401, 403):
        raise ProviderSendError("No1API rejected the credentials (HTTP %d)." % response.status_code)
    detail = str(error.get("message"))[:200] if isinstance(error, dict) and error.get("message") else ""
    raise ProviderSendError(f"No1API rejected the message (HTTP {response.status_code}). {detail}".strip())
