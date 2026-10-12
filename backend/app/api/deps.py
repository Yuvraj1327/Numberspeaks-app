"""
Shared FastAPI dependencies for the v1 endpoints.

`get_db` hands out the (service-role) Supabase client, or a clean 503 if
the server isn't configured. `get_current_user` (re-exported from
app/core/auth.py) is the ONLY source of "whose data is this" — endpoints
pass `current_user.id` to every service call and never read an owner id
from the request.
"""

import logging

from fastapi import HTTPException, status
from supabase import Client

from app.core.auth import CurrentUser, get_current_user  # noqa: F401  (re-exported)
from app.db.supabase_client import SupabaseNotConfiguredError, get_supabase
from app.services.reports_service import get_report, later_report_is_completed

logger = logging.getLogger("numberspeaks")


def get_db() -> Client:
    try:
        return get_supabase()
    except SupabaseNotConfiguredError as exc:
        raise HTTPException(status_code=status.HTTP_503_SERVICE_UNAVAILABLE, detail=str(exc)) from exc


def get_report_or_404(db: Client, owner_id: str, report_id: str) -> dict:
    """The caller's own report, or 404. A report that belongs to another
    admin is reported as 404 too — its existence is never revealed."""
    report = get_report(db, owner_id, report_id)
    if report is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail=f"No report found with id {report_id}")
    return report


def assert_report_modifiable(db: Client, owner_id: str, report: dict) -> None:
    """
    Blocks changes that would silently invalidate a LATER period.

    Carry-forward balances flow from one period into the next. If a report
    uploaded after this one has already been calculated, changing this
    report's data (or recalculating it) would leave that later report's
    "previous balance" wrong, so it is refused with a clear message.
    """
    if later_report_is_completed(db, owner_id, report):
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail=(
                "A newer report has already been calculated, so this older report can no longer be "
                "changed or recalculated — doing so would make that newer report's carried-forward "
                "balances wrong."
            ),
        )
