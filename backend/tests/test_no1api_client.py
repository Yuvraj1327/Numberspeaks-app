"""The No1API HTTP call, against a mocked transport (nothing leaves the machine)."""

import json

import httpx
import pytest

from app.core.config import get_settings
from app.services import no1api_client as c


@pytest.fixture(autouse=True)
def configured(monkeypatch):
    s = get_settings()
    monkeypatch.setattr(s, "NO1API_BASE_URL", "https://crm1.example.test//api/meta")
    monkeypatch.setattr(s, "NO1API_API_KEY", "secret-token")
    monkeypatch.setattr(s, "NO1API_API_VERSION", "v19.0")
    monkeypatch.setattr(s, "NO1API_PHONE_NUMBER_ID", "12345")


def mock(monkeypatch, handler):
    calls = []

    def post(url, json=None, headers=None, timeout=None):
        calls.append((url, json, headers))
        return handler()

    monkeypatch.setattr(c.httpx, "post", post)
    return calls


def resp(status, payload):
    return httpx.Response(status, json=payload)


def test_request_shape_and_success(monkeypatch):
    calls = mock(monkeypatch, lambda: resp(200, {"messages": [{"id": "wamid.1"}]}))
    out = c.send_text("+91 98765-43210", "hello")
    url, body, headers = calls[0]
    assert url == "https://crm1.example.test/api/meta/v19.0/12345/messages"  # '//' collapsed
    assert headers == {"Authorization": "Bearer secret-token"}
    assert body["to"] == "919876543210" and body["type"] == "text" and body["text"]["body"] == "hello"
    assert body["messaging_product"] == "whatsapp"
    assert out.provider_message_id == "wamid.1"


def test_rejection_is_failed_and_never_leaks_token(monkeypatch):
    mock(monkeypatch, lambda: resp(400, {"error": {"message": "bad param", "code": 100}}))
    with pytest.raises(c.ProviderSendError) as e:
        c.send_text("919876543210", "x")
    assert "bad param" in str(e.value) and "secret-token" not in str(e.value)


def test_outside_24h_window_has_a_clear_message(monkeypatch):
    mock(monkeypatch, lambda: resp(400, {"error": {"message": "x", "code": 131047}}))
    with pytest.raises(c.ProviderSendError, match="24 hours"):
        c.send_text("919876543210", "x")


def test_bad_credentials(monkeypatch):
    mock(monkeypatch, lambda: resp(401, {"error": {"message": "Invalid OAuth", "code": 190}}))
    with pytest.raises(c.ProviderSendError, match="token"):
        c.send_text("919876543210", "x")


@pytest.mark.parametrize("handler", [
    lambda: resp(500, {}),
    lambda: resp(200, {}),  # accepted-looking but no message id: not proven
    lambda: resp(200, {"messages": []}),
])
def test_unproven_outcomes_are_unknown(monkeypatch, handler):
    mock(monkeypatch, handler)
    with pytest.raises(c.ProviderOutcomeUnknown):
        c.send_text("919876543210", "x")


def test_timeout_is_unknown_but_connect_error_is_failed(monkeypatch):
    def timeout():
        raise httpx.ReadTimeout("t")

    mock(monkeypatch, timeout)
    with pytest.raises(c.ProviderOutcomeUnknown):
        c.send_text("919876543210", "x")

    def refused():
        raise httpx.ConnectError("no")

    mock(monkeypatch, refused)
    with pytest.raises(c.ProviderSendError, match="Nothing was sent"):
        c.send_text("919876543210", "x")


def test_unavailable_without_settings(monkeypatch):
    monkeypatch.setattr(get_settings(), "NO1API_PHONE_NUMBER_ID", "")
    assert c.is_available() is False
    with pytest.raises(c.ProviderNotConfigured):
        c.send_text("919876543210", "x")
