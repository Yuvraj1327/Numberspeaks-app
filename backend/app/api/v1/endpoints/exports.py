"""CSV exports and backup/restore. All scoped to the logged-in admin."""

from fastapi import APIRouter, Body, Depends, Response
from supabase import Client

from app.api.deps import CurrentUser, get_current_user, get_db, get_report_or_404
from app.services import backup_service

router = APIRouter(tags=["Export"])


def _csv_response(text: str, filename: str) -> Response:
    return Response(
        content=text,
        media_type="text/csv; charset=utf-8",
        headers={"Content-Disposition": f'attachment; filename="{filename}"'},
    )


@router.get("/export/users.csv", summary="Users as CSV")
def export_users(current_user: CurrentUser = Depends(get_current_user), db: Client = Depends(get_db)):
    return _csv_response(backup_service.users_csv(db, current_user.id), "users.csv")


@router.get("/export/referrals.csv", summary="Referral ledger as CSV")
def export_referrals(current_user: CurrentUser = Depends(get_current_user), db: Client = Depends(get_db)):
    return _csv_response(backup_service.referrals_csv(db, current_user.id), "referral-ledger.csv")


@router.get("/reports/{report_id}/export.csv", summary="One week's results as CSV")
def export_report(report_id: str, current_user: CurrentUser = Depends(get_current_user), db: Client = Depends(get_db)):
    get_report_or_404(db, current_user.id, report_id)
    return _csv_response(backup_service.report_csv(db, current_user.id, report_id), "week-results.csv")


@router.get("/backup", summary="Download a full JSON backup of this account's data")
def download_backup(current_user: CurrentUser = Depends(get_current_user), db: Client = Depends(get_db)):
    return backup_service.build_backup(db, current_user.id)


@router.post("/restore", summary="Restore (merge) a backup into this account")
def restore(
    backup: dict = Body(...),
    current_user: CurrentUser = Depends(get_current_user),
    db: Client = Depends(get_db),
):
    return {"restored": backup_service.restore_backup(db, current_user.id, backup)}
