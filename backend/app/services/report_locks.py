"""
Per-report mutual exclusion for calculate / validate / row-correction.

A slow client retry (e.g. tapping "Try again" after a timeout while the first
calculation is still running) must not start a second calculation of the same
report — that would write duplicate calculation_history rows and race on the
same bonus_results rows. These locks make the second request fail fast with
409 instead. They are per process (the API runs as a single uvicorn process).
"""

from contextlib import contextmanager
from threading import Lock
from typing import Dict, Iterator

from fastapi import HTTPException, status

_guard = Lock()
_locks: Dict[str, Lock] = {}


@contextmanager
def report_busy_guard(report_id: str, action: str) -> Iterator[None]:
    """Holds the report's lock for the block, or raises 409 if another
    calculate/validate/correction is already running on it."""
    with _guard:
        lock = _locks.setdefault(report_id, Lock())
    if not lock.acquire(blocking=False):
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail=f"This report is busy: another change is still being saved, so the {action} was not "
            "started. Wait a moment and try again.",
        )
    try:
        yield
    finally:
        lock.release()
