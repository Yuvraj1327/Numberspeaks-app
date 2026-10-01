"""
Report upload, status, and validation endpoints.

Upload is asynchronous: POST /reports/upload only checks that the file is
a PDF, stores it, creates the report row and queues it for background
processing (app/services/report_processor.py), then returns immediately
with the report id. The client polls GET /reports/{id}/status until it is
'completed' or 'failed', then reads GET /reports/{id}/results.

POST /reports/{id}/validate is the older manual step and is kept for
compatibility; it refuses to run while the background job owns the report.
"""

import logging
import uuid

from fastapi import APIRouter, Depends, File, HTTPException, Query, UploadFile, status

from app.core.auth import AuthUser, can_access_report, get_current_user
from app.core.config import get_settings
from app.db.supabase_client import SupabaseNotConfiguredError, get_supabase
from app.schemas.report import ReportListItem, ReportStatusResponse, UploadReportResponse
from app.schemas.validation import ValidationSummary
from app.services.report_processor import resume_if_abandoned, submit_report
from app.services.reports_service import (
    ACTIVE_STATUSES,
    REPORTS_BUCKET,
    bonus_result_row_to_raw,
    create_report,
    default_row_reference,
    get_bonus_results_for_report,
    get_report,
    list_reports,
    safe_error,
    storage_path_for,
    update_report_status,
    upload_pdf_to_storage,
)
from app.services.validation import validate_records

logger = logging.getLogger("numberspeaks")

router = APIRouter(prefix="/reports", tags=["Reports"])

FINAL_STATUSES = ("completed", "failed")


@router.post(
    "/upload",
    response_model=UploadReportResponse,
    status_code=status.HTTP_202_ACCEPTED,
    summary="Upload a report PDF and start processing it in the background",
)
def upload_report(
    file: UploadFile = File(..., description="The 'Party Profit Loss' PDF report"),
    user: AuthUser = Depends(get_current_user),
) -> UploadReportResponse:
    # --- 1. Validate the upload is a PDF -----------------------------------
    filename = file.filename or "upload.pdf"
    is_pdf_extension = filename.lower().endswith(".pdf")
    is_pdf_content_type = (file.content_type or "").lower() == "application/pdf"

    if not is_pdf_extension or not is_pdf_content_type:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="Only PDF files are accepted (expected a .pdf file with content-type application/pdf).",
        )

    max_bytes = get_settings().MAX_UPLOAD_MB * 1024 * 1024
    file_bytes = file.file.read(max_bytes + 1)

    if not file_bytes:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="The uploaded file is empty.")

    if len(file_bytes) > max_bytes:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail=f"File too large. Maximum allowed size is {get_settings().MAX_UPLOAD_MB} MB.",
        )

    if b"%PDF-" not in file_bytes[:1024]:
        raise HTTPException(status_code=status.HTTP_422_UNPROCESSABLE_ENTITY, detail="The file is not a valid PDF.")

    # --- 2. Store the file, then register the report ------------------------
    # The file goes first so a report row never exists without its PDF, and
    # the background job can always fetch the PDF back from storage.
    try:
        db = get_supabase()
    except SupabaseNotConfiguredError as exc:
        raise HTTPException(status_code=status.HTTP_503_SERVICE_UNAVAILABLE, detail=str(exc)) from exc

    report_id = str(uuid.uuid4())

    try:
        storage_path = upload_pdf_to_storage(db, report_id, filename, file_bytes)
    except Exception as exc:  # noqa: BLE001
        logger.error("Failed to upload PDF to storage for report %s: %s", report_id, safe_error(exc))
        raise HTTPException(
            status_code=status.HTTP_502_BAD_GATEWAY,
            detail=(
                "The file could not be stored. Make sure the "
                f"'{REPORTS_BUCKET}' Storage bucket exists (see supabase/storage_setup.sql)."
            ),
        ) from exc

    try:
        create_report(db, report_id, filename, storage_path, owner_id=user.id)
    except Exception as exc:  # noqa: BLE001
        logger.error("Failed to create report record %s: %s", report_id, safe_error(exc))
        try:
            db.storage.from_(REPORTS_BUCKET).remove([storage_path_for(report_id, filename)])
        except Exception:  # noqa: BLE001
            logger.warning("Could not remove orphaned file for report %s", report_id)
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="Could not save report to the database.",
        ) from exc

    # --- 3. Hand off to the background worker and return ---------------------
    submit_report(report_id)
    logger.info("Report %s accepted (%d bytes); processing queued", report_id, len(file_bytes))

    return UploadReportResponse(
        report_id=report_id,
        file_name=filename,
        status="uploaded",
        pages_processed=0,
        total_records=0,
        records=[],
        warnings=[],
    )


@router.get(
    "",
    response_model=list[ReportListItem],
    summary="List the signed-in account's reports, newest first",
)
def list_my_reports(
    limit: int = Query(20, ge=1, le=100),
    all_accounts: bool = Query(False, alias="all", description="Admins only: include every account's reports."),
    user: AuthUser = Depends(get_current_user),
) -> list[ReportListItem]:
    if all_accounts and not user.is_admin:
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="Only admins can list every account's reports.")

    try:
        db = get_supabase()
    except SupabaseNotConfiguredError as exc:
        raise HTTPException(status_code=status.HTTP_503_SERVICE_UNAVAILABLE, detail=str(exc)) from exc

    try:
        rows = list_reports(db, None if all_accounts else user.id, limit)
    except Exception as exc:  # noqa: BLE001
        logger.error("Failed to list reports: %s", safe_error(exc))
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="Could not read reports from the database.",
        ) from exc

    return [
        ReportListItem(
            report_id=row["id"],
            file_name=row.get("file_name") or "",
            status=row["status"],
            total_records=row.get("total_records") or 0,
            calculated_count=row.get("calculated_count") or 0,
            failed_count=row.get("failed_count") or 0,
            uploaded_at=row.get("uploaded_at"),
            updated_at=row.get("updated_at"),
        )
        for row in rows
    ]


@router.get(
    "/{report_id}/status",
    response_model=ReportStatusResponse,
    summary="Get a report's processing status",
)
def get_report_status(report_id: str, user: AuthUser = Depends(get_current_user)) -> ReportStatusResponse:
    try:
        uuid.UUID(report_id)
    except ValueError:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail=f"No report found with id {report_id}")

    try:
        db = get_supabase()
    except SupabaseNotConfiguredError as exc:
        raise HTTPException(status_code=status.HTTP_503_SERVICE_UNAVAILABLE, detail=str(exc)) from exc

    try:
        report = get_report(db, report_id)
    except Exception as exc:  # noqa: BLE001
        logger.error("Failed to look up report %s: %s", report_id, safe_error(exc))
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="Could not read report from the database.",
        ) from exc

    # Someone else's report is reported exactly like a missing one.
    if report is None or not can_access_report(report, user):
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail=f"No report found with id {report_id}")

    # A job that was lost to a restart is resumed here; the status returned
    # below is the truthful current one either way.
    resume_if_abandoned(report)

    return ReportStatusResponse(
        report_id=report["id"],
        file_name=report.get("file_name") or "",
        status=report["status"],
        is_final=report["status"] in FINAL_STATUSES,
        pages_processed=report.get("pages_processed") or 0,
        total_records=report.get("total_records") or 0,
        calculated_count=report.get("calculated_count") or 0,
        failed_count=report.get("failed_count") or 0,
        error_message=report.get("error_message"),
        warnings=report.get("warnings") or [],
        uploaded_at=report.get("uploaded_at"),
        updated_at=report.get("updated_at"),
    )


@router.post(
    "/{report_id}/validate",
    response_model=ValidationSummary,
    summary="Validate a report's extracted rows before bonus calculation",
)
def validate_report(report_id: str, user: AuthUser = Depends(get_current_user)) -> ValidationSummary:
    try:
        db = get_supabase()
    except SupabaseNotConfiguredError as exc:
        raise HTTPException(status_code=status.HTTP_503_SERVICE_UNAVAILABLE, detail=str(exc)) from exc

    try:
        report = get_report(db, report_id)
    except Exception as exc:  # noqa: BLE001
        logger.exception("Failed to look up report %s", report_id)
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail=f"Could not read report from the database: {exc}",
        ) from exc

    # Someone else's report is reported exactly like a missing one.
    if report is None or not can_access_report(report, user):
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail=f"No report found with id {report_id}")

    if report.get("status") in ("uploaded", *ACTIVE_STATUSES):
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail=(
                f"This report is still being processed in the background "
                f"(current status: {report.get('status')!r}). "
                f"Check GET /api/v1/reports/{report_id}/status."
            ),
        )

    try:
        rows = get_bonus_results_for_report(db, report_id)
    except Exception as exc:  # noqa: BLE001
        logger.exception("Failed to load extracted rows for report %s", report_id)
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail=f"Could not read this report's extracted rows: {exc}",
        ) from exc

    raw_rows = [bonus_result_row_to_raw(row) for row in rows]
    result = validate_records(raw_rows, default_row_reference)

    if not raw_rows or not result.valid_records:
        new_status = "failed"
    else:
        new_status = "validated"

    update_report_status(db, report_id, new_status)

    return ValidationSummary(
        report_id=report_id,
        status=new_status,
        total_input_records=len(raw_rows),
        valid_count=len(result.valid_records),
        invalid_count=len(result.invalid_records),
        valid_records=result.valid_records,
        invalid_records=result.invalid_records,
    )
