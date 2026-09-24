"""
Supabase connection/service layer.

This is the ONLY place in the app that should construct a Supabase client.
Every other module (future PDF, validation, bonus, and WhatsApp modules)
imports `get_supabase()` from here rather than creating its own connection.
That keeps configuration, error handling, and (later) any retry/caching
logic in one spot.
"""

from functools import lru_cache

from fastapi import HTTPException, status
from supabase import Client, create_client

from app.core.config import get_settings


class SupabaseNotConfiguredError(RuntimeError):
    """Raised when SUPABASE_URL / SUPABASE_KEY are missing."""


@lru_cache
def get_supabase() -> Client:
    """
    Returns a cached Supabase client built from environment configuration.

    Cached with lru_cache so the client (and its underlying HTTP session)
    is created once per process, not on every request.
    """
    settings = get_settings()

    if not settings.has_supabase_config:
        raise SupabaseNotConfiguredError(
            "SUPABASE_URL and SUPABASE_KEY must be set in the environment (.env)."
        )

    return create_client(settings.SUPABASE_URL, settings.SUPABASE_KEY)


def get_supabase_dependency() -> Client:
    """
    FastAPI dependency version of get_supabase().

    Use this in route signatures (e.g. `db: Client = Depends(get_supabase_dependency)`)
    so a missing/misconfigured Supabase connection surfaces as a clean 503
    response instead of a raw exception.
    """
    try:
        return get_supabase()
    except SupabaseNotConfiguredError as exc:
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail=str(exc),
        ) from exc
