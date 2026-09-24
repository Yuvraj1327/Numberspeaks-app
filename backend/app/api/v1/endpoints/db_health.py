"""
Database connectivity check.

Separate from the plain /health endpoint on purpose: /health proves the API
process is alive with zero dependencies, while this one proves the API can
actually reach Supabase. Useful for diagnosing "backend is up but DB is
misconfigured" situations without digging through logs.

This only performs a read (a row count), so it's safe to call anytime and
never writes test data into real tables.
"""

from fastapi import APIRouter, Depends, HTTPException, status
from supabase import Client

from app.db.supabase_client import get_supabase_dependency

router = APIRouter()


@router.get("/health/db", tags=["Health"], summary="Database connectivity check")
def db_health_check(db: Client = Depends(get_supabase_dependency)) -> dict:
    try:
        # HEAD + count avoids pulling any actual row data back.
        result = db.table("users").select("id", count="exact").limit(1).execute()
    except Exception as exc:  # noqa: BLE001 - surfaced as a clean 503 below
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail=f"Could not reach Supabase: {exc}",
        ) from exc

    return {
        "status": "ok",
        "database": "connected",
        "users_table_row_count": result.count,
    }
