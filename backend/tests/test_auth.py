"""Authentication: every data endpoint requires a verified Supabase login."""

import httpx
import pytest
from fastapi import HTTPException
from fastapi.testclient import TestClient

from app.api.deps import get_db
from app.core import auth
from app.core.config import get_settings
from app.main import app
from tests.fake_supabase import FakeSupabase

USER_ID = "11111111-2222-4333-8444-555555555555"


@pytest.fixture()
def configured(monkeypatch):
    monkeypatch.setenv("SUPABASE_URL", "https://example.supabase.co")
    monkeypatch.setenv("SUPABASE_KEY", "service-key")
    get_settings.cache_clear()
    yield
    get_settings.cache_clear()


def mock_client(handler):
    return httpx.Client(transport=httpx.MockTransport(handler))


# --- header parsing --------------------------------------------------------------
@pytest.mark.parametrize("header", [None, "", "Token abc", "Bearer", "Bearer   ", "abc"])
def test_bad_authorization_headers_are_401(header):
    with pytest.raises(HTTPException) as exc:
        auth.extract_bearer_token(header)
    assert exc.value.status_code == 401


def test_bearer_token_extracted():
    assert auth.extract_bearer_token("Bearer abc.def.ghi") == "abc.def.ghi"
    assert auth.extract_bearer_token("bearer  xyz ") == "xyz"


# --- verification against Supabase Auth -------------------------------------------
def test_valid_token_returns_the_user_id_from_supabase(configured):
    seen = {}

    def handler(request: httpx.Request):
        seen["url"] = str(request.url)
        seen["auth"] = request.headers["authorization"]
        seen["apikey"] = request.headers["apikey"]
        return httpx.Response(200, json={"id": USER_ID, "email": "admin@example.com"})

    user = auth.verify_supabase_token("tok123", mock_client(handler))
    assert user.id == USER_ID and user.email == "admin@example.com"
    assert seen["url"] == "https://example.supabase.co/auth/v1/user"
    assert seen["auth"] == "Bearer tok123" and seen["apikey"] == "service-key"


@pytest.mark.parametrize("status", [400, 401, 403])
def test_rejected_token_is_401(configured, status):
    with pytest.raises(HTTPException) as exc:
        auth.verify_supabase_token("bad", mock_client(lambda r: httpx.Response(status, json={"msg": "nope"})))
    assert exc.value.status_code == 401


@pytest.mark.parametrize("status", [500, 502, 429])
def test_auth_server_trouble_is_503_never_trusted(configured, status):
    with pytest.raises(HTTPException) as exc:
        auth.verify_supabase_token("tok", mock_client(lambda r: httpx.Response(status)))
    assert exc.value.status_code == 503


def test_unreachable_auth_server_is_503(configured):
    def boom(request):
        raise httpx.ConnectError("down")

    with pytest.raises(HTTPException) as exc:
        auth.verify_supabase_token("tok", mock_client(boom))
    assert exc.value.status_code == 503


@pytest.mark.parametrize("payload", [{}, {"id": None}, {"id": 5}, ["x"], "str"])
def test_response_without_a_user_id_is_401(configured, payload):
    with pytest.raises(HTTPException) as exc:
        auth.verify_supabase_token("tok", mock_client(lambda r: httpx.Response(200, json=payload)))
    assert exc.value.status_code == 401


def test_not_configured_is_503(monkeypatch):
    monkeypatch.setenv("SUPABASE_URL", "")
    monkeypatch.setenv("SUPABASE_KEY", "")
    get_settings.cache_clear()
    try:
        with pytest.raises(HTTPException) as exc:
            auth.verify_supabase_token("tok", mock_client(lambda r: httpx.Response(200, json={"id": USER_ID})))
        assert exc.value.status_code == 503
    finally:
        get_settings.cache_clear()


# --- the real dependency protects every data route ----------------------------------
PROTECTED = [
    ("get", "/api/v1/reports"),
    ("get", "/api/v1/reports/00000000-0000-4000-8000-000000000001"),
    ("get", "/api/v1/reports/00000000-0000-4000-8000-000000000001/results"),
    ("get", "/api/v1/reports/00000000-0000-4000-8000-000000000001/results/x"),
    ("post", "/api/v1/reports/upload"),
    ("patch", "/api/v1/reports/x/rows/y"),
    ("post", "/api/v1/reports/x/validate"),
    ("post", "/api/v1/reports/x/calculate-bonus"),
    ("get", "/api/v1/reports/x/referrals"),
    ("post", "/api/v1/reports/x/referrals"),
    ("delete", "/api/v1/reports/x/referrals/y"),
    ("get", "/api/v1/users"),
    ("get", "/api/v1/users/x"),
    ("patch", "/api/v1/users/x"),
    ("get", "/api/v1/users/x/history"),
    ("get", "/api/v1/settings"),
    ("put", "/api/v1/settings"),
    ("post", "/api/v1/reports/x/results/y/whatsapp-send"),
    ("post", "/api/v1/reports/x/whatsapp-bulk"),
    ("get", "/api/v1/reports/x/whatsapp-bulk/y"),
    ("get", "/api/v1/whatsapp/test-status"),
    ("post", "/api/v1/whatsapp/test-send"),
]


@pytest.fixture()
def raw_client(configured):
    """No auth override — the real get_current_user runs; the DB is faked."""
    fake = FakeSupabase()
    app.dependency_overrides[get_db] = lambda: fake
    try:
        yield TestClient(app, raise_server_exceptions=False)
    finally:
        app.dependency_overrides.clear()


@pytest.mark.parametrize("method, url", PROTECTED)
def test_every_data_route_requires_a_token(raw_client, method, url):
    r = getattr(raw_client, method)(url)
    assert r.status_code == 401, f"{method.upper()} {url} -> {r.status_code}"
    assert r.headers.get("www-authenticate") == "Bearer"


def test_a_bad_token_is_rejected_by_the_real_dependency(raw_client, monkeypatch):
    monkeypatch.setattr(auth, "httpx", httpx)  # use real httpx but force the response below
    real_client = httpx.Client

    def fake_client(*a, **kw):
        return real_client(transport=httpx.MockTransport(lambda r: httpx.Response(401, json={})))

    monkeypatch.setattr(auth.httpx, "Client", fake_client)
    r = raw_client.get("/api/v1/reports", headers={"Authorization": "Bearer forged"})
    assert r.status_code == 401


def test_a_good_token_reaches_the_endpoint_as_that_user(raw_client, monkeypatch):
    real_client = httpx.Client

    def fake_client(*a, **kw):
        return real_client(transport=httpx.MockTransport(lambda r: httpx.Response(200, json={"id": USER_ID})))

    monkeypatch.setattr(auth.httpx, "Client", fake_client)
    r = raw_client.get("/api/v1/reports", headers={"Authorization": "Bearer good"})
    assert r.status_code == 200 and r.json() == []


def test_health_is_public(raw_client):
    assert raw_client.get("/api/v1/health").status_code == 200
    assert raw_client.get("/").status_code == 200


def test_no_service_role_key_or_secret_is_ever_returned(raw_client):
    body = raw_client.get("/api/v1/health").text + raw_client.get("/").text
    assert "service-key" not in body
