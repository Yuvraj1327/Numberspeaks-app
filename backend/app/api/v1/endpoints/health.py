"""
Health-check endpoint.

Used by Railway (and anyone else) to confirm the service is up and
responding. Deliberately has no dependencies on the database or any
external service — this only proves the API process itself is alive.
"""

from fastapi import APIRouter

router = APIRouter()


@router.get("/health", tags=["Health"], summary="Health check")
def health_check() -> dict:
    return {
        "status": "ok",
        "service": "numberspeaks-api",
    }
