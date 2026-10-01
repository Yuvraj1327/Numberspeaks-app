"""
Authentication for the API.

The Flutter app signs in with Supabase Auth and sends the session's access
token as `Authorization: Bearer <token>`. Every report endpoint depends on
get_current_user(), which asks Supabase Auth who the token belongs to
(GET /auth/v1/user — this checks the signature, expiry and that the session
has not been signed out) and returns that user. The user id comes from
Supabase, never from anything the client sends in the request body or URL.

Ownership rule used by every report endpoint (see can_access_report): a
report is visible to the account that uploaded it (reports.owner_id) and to
admins. Reports with no owner (uploaded before ownership existed) are
visible to admins only.

Admin = Supabase `app_metadata.role == "admin"` (set only server-side, a
user cannot edit it) or a user id listed in ADMIN_USER_IDS.
"""

import hashlib
import logging
import time
from dataclasses import dataclass
from threading import Lock
from typing import Dict, Optional, Tuple

import httpx
from fastapi import Depends, HTTPException, status
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer

from app.core.config import get_settings

logger = logging.getLogger("numberspeaks")

# A verified token is remembered this long, so the status polling the app
# does every few seconds doesn't cost a Supabase Auth call each time. A
# sign-out therefore takes at most this long to take effect.
TOKEN_CACHE_SECONDS = 30.0
TOKEN_CACHE_MAX_ENTRIES = 1000

_bearer = HTTPBearer(auto_error=False)
_cache: Dict[str, Tuple[float, "AuthUser"]] = {}
_cache_lock = Lock()


@dataclass(frozen=True)
class AuthUser:
    id: str
    email: Optional[str] = None
    is_admin: bool = False


def _unauthorized(detail: str) -> HTTPException:
    return HTTPException(
        status_code=status.HTTP_401_UNAUTHORIZED,
        detail=detail,
        headers={"WWW-Authenticate": "Bearer"},
    )


def _cache_key(token: str) -> str:
    return hashlib.sha256(token.encode()).hexdigest()


def _fetch_user(token: str) -> AuthUser:
    settings = get_settings()
    if not settings.has_supabase_config:
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="SUPABASE_URL and SUPABASE_KEY must be set in the environment (.env).",
        )

    try:
        response = httpx.get(
            f"{settings.SUPABASE_URL.rstrip('/')}/auth/v1/user",
            headers={"Authorization": f"Bearer {token}", "apikey": settings.SUPABASE_KEY},
            timeout=10.0,
        )
    except httpx.HTTPError as exc:
        logger.error("Could not reach Supabase Auth: %s", type(exc).__name__)
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="Could not verify your session. Please try again.",
        ) from exc

    if response.status_code in (401, 403):
        raise _unauthorized("Invalid or expired session. Please log in again.")
    if response.status_code != 200:
        logger.error("Supabase Auth returned HTTP %s while verifying a token", response.status_code)
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="Could not verify your session. Please try again.",
        )

    data = response.json()
    user_id = data.get("id")
    if not user_id:
        raise _unauthorized("Invalid or expired session. Please log in again.")

    is_admin = (data.get("app_metadata") or {}).get("role") == "admin" or user_id in settings.admin_user_ids
    return AuthUser(id=str(user_id), email=data.get("email"), is_admin=is_admin)


def get_current_user(
    credentials: Optional[HTTPAuthorizationCredentials] = Depends(_bearer),
) -> AuthUser:
    """FastAPI dependency: the authenticated user, or 401."""
    if credentials is None or not credentials.credentials:
        raise _unauthorized("Not authenticated. Please log in.")

    token = credentials.credentials
    key = _cache_key(token)
    now = time.monotonic()

    with _cache_lock:
        cached = _cache.get(key)
        if cached and cached[0] > now:
            return cached[1]

    user = _fetch_user(token)

    with _cache_lock:
        if len(_cache) >= TOKEN_CACHE_MAX_ENTRIES:
            for stale in [k for k, (expires, _) in _cache.items() if expires <= now]:
                del _cache[stale]
            if len(_cache) >= TOKEN_CACHE_MAX_ENTRIES:
                _cache.clear()
        _cache[key] = (now + TOKEN_CACHE_SECONDS, user)
    return user


def can_access_report(report: dict, user: AuthUser) -> bool:
    """True if `user` may read or act on `report`."""
    if user.is_admin:
        return True
    owner_id = report.get("owner_id")
    return owner_id is not None and str(owner_id) == user.id
