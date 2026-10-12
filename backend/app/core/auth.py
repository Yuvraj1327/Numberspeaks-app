"""
Authentication — who is calling this API.

Every data endpoint depends on `get_current_user`. It takes the caller's
Supabase access token from the `Authorization: Bearer <token>` header and
asks the project's own Supabase Auth server (GET /auth/v1/user) to verify
it. That single call checks the signature, the expiry and that the session
has not been revoked, and it works the same whichever JWT signing method
the Supabase project uses (legacy shared secret or the newer asymmetric
signing keys) — so no JWT secret has to be copied into this backend.

The returned user id is the ONLY source of ownership in this API. Routes
and services never accept an owner/user id from the request body, query
string or path for the purpose of deciding whose data to touch: they pass
`current_user.id` into every query. (The service-role Supabase client used
by this backend bypasses Row Level Security, so this scoping in code is
what actually isolates one admin's data from another's.)
"""

import logging
from dataclasses import dataclass
from typing import Optional

import httpx
from fastapi import HTTPException, Request, status

from app.core.config import get_settings

logger = logging.getLogger("numberspeaks")

AUTH_TIMEOUT_SECONDS = 10.0


@dataclass(frozen=True)
class CurrentUser:
    """The verified, authenticated admin making the request."""

    id: str
    email: Optional[str] = None


def _unauthorized(detail: str) -> HTTPException:
    return HTTPException(
        status_code=status.HTTP_401_UNAUTHORIZED,
        detail=detail,
        headers={"WWW-Authenticate": "Bearer"},
    )


def extract_bearer_token(authorization_header: Optional[str]) -> str:
    """Pulls the token out of an `Authorization: Bearer <token>` header, or
    raises 401 if the header is missing or not in that form."""
    if not authorization_header:
        raise _unauthorized("Missing Authorization header. Log in and send 'Authorization: Bearer <token>'.")
    scheme, _, token = authorization_header.partition(" ")
    if scheme.lower() != "bearer" or not token.strip():
        raise _unauthorized("Authorization header must be in the form 'Bearer <token>'.")
    return token.strip()


def verify_supabase_token(token: str, client: Optional[httpx.Client] = None) -> CurrentUser:
    """
    Verifies `token` against the Supabase Auth server and returns the user.

    401 -> the token is invalid/expired/revoked.
    503 -> Supabase isn't configured on this server, or the auth server
           couldn't be reached (we never fall back to trusting the token).

    `client` is injectable so tests can supply a mock transport.
    """
    settings = get_settings()
    if not settings.has_supabase_config:
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="SUPABASE_URL and SUPABASE_KEY must be set in the environment (.env).",
        )

    url = settings.SUPABASE_URL.rstrip("/") + "/auth/v1/user"
    headers = {"Authorization": f"Bearer {token}", "apikey": settings.SUPABASE_KEY}

    owns_client = client is None
    http = client or httpx.Client(timeout=AUTH_TIMEOUT_SECONDS)
    try:
        response = http.get(url, headers=headers)
    except httpx.HTTPError as exc:
        logger.warning("Could not reach Supabase Auth to verify a token: %s", exc)
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="Could not reach the authentication service. Please try again.",
        ) from exc
    finally:
        if owns_client:
            http.close()

    if response.status_code in (400, 401, 403):
        raise _unauthorized("Your session is invalid or has expired. Please log in again.")
    if response.status_code != 200:
        logger.warning("Supabase Auth returned unexpected status %s while verifying a token", response.status_code)
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="The authentication service returned an unexpected response.",
        )

    try:
        payload = response.json()
    except ValueError as exc:
        raise _unauthorized("Your session could not be verified.") from exc

    user_id = payload.get("id") if isinstance(payload, dict) else None
    if not user_id or not isinstance(user_id, str):
        raise _unauthorized("Your session could not be verified.")

    return CurrentUser(id=user_id, email=payload.get("email"))


def get_current_user(request: Request) -> CurrentUser:
    """FastAPI dependency: the verified admin for this request.

    Declared as a plain `def` (not `async def`) on purpose — it makes a
    blocking HTTP call, so FastAPI runs it in its thread pool instead of
    stalling the event loop.
    """
    token = extract_bearer_token(request.headers.get("authorization"))
    return verify_supabase_token(token)
