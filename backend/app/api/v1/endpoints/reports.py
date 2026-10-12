"""
Report upload, extraction, review/correction and validation endpoints.

Upload: accept the PDF, extract its table data into structured records,
store the file and results. The admin can then REVIEW the extracted rows
(GET /reports/{id}/results), CORRECT any misread value (PATCH
/reports/{id}/rows/{row_id}), validate, and finally confirm the bonus
calculation (see bonus.py). Nothing is calculated until the admin confirms.

Every endpoint requires a logged-in admin; every query is scoped to that
admin (see app/core/auth.py and app/services/reports_service.py).

Order of operations on upload is deliberate: the file is validated and
extracted BEFORE anything touches Supabase, so a bad upload (wrong type,
unreadable PDF) fails fast with a clear 4xx and never creates a database
row.
"""

import logging
from datetime import date
from typing import List, Optional

from fastapi.concurrency import run_in_threadpool
from fastapi import APIRouter, Depends, File, Form, HTTPException, Response, UploadFile, status
from supabase import Client

from app.api.deps import CurrentUser, assert_report_modifiable, get_current_user, get_db, get_report_or_404
from app.schemas.bonus import BonusResult, RowCorrection
from app.schemas.report import ReportSummary, UploadReportResponse
from app.schemas.validation import ValidationSummary
from app.services.corrections_service import apply_row_correction
from app.services.report_locks import report_busy_guard
from app.services.referral_service import restore_referrals, snapshot_referrals
from app.services.pdf_extractor import PdfExtractionError, extract_records_from_pdf
from app.services.reports_service import (
    bonus_result_row_to_raw,
    create_report,
    default_row_reference,
    delete_report,
    find_period_conflicts,
    first_later_completed_report,
    get_bonus_results_for_report,
    list_reports,
    save_extracted_records,
    to_bonus_result,
    to_report_summary,
    update_report_file_path,
    update_report_status,
    update_report_summary,
    upload_pdf_to_storage,
)
from app.services.validation import validate_records

logger = logging.getLogger("numberspeaks")

router = APIRouter(prefix="/reports", tags=["Reports"])

MAX_FILE_SIZE_BYTES = 20 * 1024 * 1024  # 20 MB.


@router.get("", response_model=List[ReportSummary], summary="List this admin's reports (history), newest first")
def list_my_reports(
    current_user: CurrentUser = Depends(get_current_user),
    db: Client = Depends(get_db),
) -> List[ReportSummary]:
    return [to_report_summary(row) for row in list_reports(db, current_user.id)]


@router.get("/{report_id}", response_model=ReportSummary, summary="Get one report")
def get_one_report(
    report_id: str,
    current_user: CurrentUser = Depends(get_current_user),
    db: Client = Depends(get_db),
) -> ReportSummary:
    return to_report_summary(get_report_or_404(db, current_user.id, report_id))


@router.delete(
    "/{report_id}",
    status_code=status.HTTP_204_NO_CONTENT,
    summary="Delete one of this admin's reports with its results, records and stored PDF",
)
def delete_one_report(
    report_id: str,
    current_user: CurrentUser = Depends(get_current_user),
    db: Client = Depends(get_db),
) -> Response:
    with report_busy_guard(report_id, "deletion"):
        # 404 for a missing report AND for another admin's: existence is never revealed.
        report = get_report_or_404(db, current_user.id, report_id)
        if report.get("status") == "completed":
            # A later period's carried-forward balances were computed from this
            # one, so it can only go once no newer report is calculated.
            newer = first_later_completed_report(db, current_user.id, report)
            if newer is not None:
                raise HTTPException(
                    status_code=status.HTTP_409_CONFLICT,
                    detail=(
                        "This report can't be deleted yet: a newer report "
                        f"('{newer.get('file_name') or 'Report'}') has already been calculated using this "
                        "report's carried-forward balances. Delete the newer report first."
                    ),
                )
        delete_report(db, current_user.id, report)
    return Response(status_code=status.HTTP_204_NO_CONTENT)


@router.post("/upload", response_model=UploadReportResponse, summary="Upload and extract a report PDF")
async def upload_report(
    file: UploadFile = File(..., description="The 'Party Profit Loss' PDF report"),
    period_start: Optional[str] = Form(None, description="First day of the week, YYYY-MM-DD"),
    period_end: Optional[str] = Form(None, description="Last day of the week, YYYY-MM-DD"),
    replace: bool = Form(False, description="Deliberately replace the report already imported for this period"),
    current_user: CurrentUser = Depends(get_current_user),
    db: Client = Depends(get_db),
) -> UploadReportResponse:
    owner_id = current_user.id
    start, end = _parse_period(period_start, period_end)

    # --- 1. Validate the upload is a PDF -----------------------------------
    filename = file.filename or "upload.pdf"
    is_pdf_extension = filename.lower().endswith(".pdf")
    is_pdf_content_type = (file.content_type or "").lower() == "application/pdf"

    if not is_pdf_extension or not is_pdf_content_type:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="Only PDF files are accepted (expected a .pdf file with content-type application/pdf).",
        )

    file_bytes = await file.read()

    if not file_bytes:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="The uploaded file is empty.")

    if len(file_bytes) > MAX_FILE_SIZE_BYTES:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail=f"File too large. Maximum allowed size is {MAX_FILE_SIZE_BYTES // (1024 * 1024)} MB.",
        )

    # Extraction (CPU) and every Supabase call below are blocking, so they run
    # in the threadpool — never on the event loop, which would stall every
    # other request (status checks, row saves) for the whole upload.
    return await run_in_threadpool(_extract_and_store, db, owner_id, filename, file_bytes, start, end, replace)


MAX_PERIOD_DAYS = 31


def _parse_period(period_start: Optional[str], period_end: Optional[str]):
    """Both dates or neither (legacy upload without a period)."""
    if not period_start and not period_end:
        return None, None
    if not (period_start and period_end):
        raise HTTPException(status_code=422, detail="Send both period_start and period_end, or neither.")
    try:
        start, end = date.fromisoformat(period_start), date.fromisoformat(period_end)
    except ValueError as exc:
        raise HTTPException(status_code=422, detail="Period dates must be YYYY-MM-DD.") from exc
    if end < start:
        raise HTTPException(status_code=422, detail="The period end date is before its start date.")
    if (end - start).days >= MAX_PERIOD_DAYS:
        raise HTTPException(status_code=422, detail=f"A period can span at most {MAX_PERIOD_DAYS} days.")
    return start.isoformat(), end.isoformat()


def _check_period(db: Client, owner_id: str, start: Optional[str], end: Optional[str], replace: bool) -> Optional[dict]:
    """Rejects a duplicate/overlapping period. Returns the report to replace
    (only when the admin explicitly asked to replace an identical period)."""
    if not start:
        return None
    same, overlap = find_period_conflicts(db, owner_id, start, end)
    if same is None and overlap is not None:
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail=(
                f"This period overlaps an existing report ({overlap['period_start']} to {overlap['period_end']}). "
                "Each week can only be imported once."
            ),
        )
    if same is None:
        return None
    if not replace:
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail=f"A report for {start} to {end} already exists. Confirm to replace it, or pick another week.",
            headers={"X-Error-Code": "period_exists"},
        )
    if same.get("status") == "completed":
        newer = first_later_completed_report(db, owner_id, same)
        if newer is not None:
            raise HTTPException(
                status_code=status.HTTP_409_CONFLICT,
                detail=(
                    "This week can't be replaced: a later week has already been calculated using its "
                    "carried-forward balances. Delete the later week(s) first."
                ),
            )
    return same


def _extract_and_store(
    db: Client,
    owner_id: str,
    filename: str,
    file_bytes: bytes,
    period_start: Optional[str] = None,
    period_end: Optional[str] = None,
    replace: bool = False,
) -> UploadReportResponse:
    old_report = _check_period(db, owner_id, period_start, period_end, replace)

    # --- 2. Extract table data from every page (no DB involved yet) ---------
    try:
        extraction = extract_records_from_pdf(file_bytes)
    except PdfExtractionError as exc:
        raise HTTPException(status_code=status.HTTP_422_UNPROCESSABLE_ENTITY, detail=str(exc)) from exc
    except Exception as exc:  # noqa: BLE001
        logger.exception("Unexpected extraction failure for %s", filename)
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail="Unexpected error while extracting the PDF.",
        ) from exc

    # --- 3. Create the report record, then store the file ----------------------
    try:
        # When replacing, the new report is created WITHOUT its period first so
        # the old week stays intact until the new one is fully saved.
        report = create_report(db, owner_id, filename, None if old_report else period_start, None if old_report else period_end)
        report_id = report["id"]
    except Exception as exc:  # noqa: BLE001
        logger.exception("Failed to create report record")
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="Could not save the report to the database.",
        ) from exc

    try:
        storage_path = upload_pdf_to_storage(db, report_id, filename, file_bytes)
        update_report_file_path(db, owner_id, report_id, storage_path)
    except Exception as exc:  # noqa: BLE001
        logger.exception("Failed to upload PDF to storage for report %s", report_id)
        update_report_status(db, owner_id, report_id, "failed")
        raise HTTPException(
            status_code=status.HTTP_502_BAD_GATEWAY,
            detail=(
                "The report was registered but the file could not be stored. Make sure the "
                "'reports' Storage bucket exists (see supabase/storage_setup.sql)."
            ),
        ) from exc

    # --- 4. Save the extracted rows ---------------------------------------------
    saved_count, save_warnings = save_extracted_records(db, owner_id, report_id, extraction.records)

    # "processing" = extracted and stored, awaiting the admin's review.
    update_report_status(db, owner_id, report_id, "processing")
    update_report_summary(db, owner_id, report_id, {"user_count": saved_count})

    if old_report is not None:
        kept = snapshot_referrals(db, owner_id, old_report["id"])
        with report_busy_guard(old_report["id"], "replacement"):
            delete_report(db, owner_id, old_report)
        update_report_summary(db, owner_id, report_id, {"period_start": period_start, "period_end": period_end})
        restore_referrals(db, owner_id, report_id, kept)

    return UploadReportResponse(
        report_id=report_id,
        file_name=filename,
        period_start=period_start,
        period_end=period_end,
        replaced_report_id=old_report["id"] if old_report else None,
        status="processing",
        pages_processed=extraction.pages_processed,
        total_records=saved_count,
        records=extraction.records,
        warnings=[*extraction.warnings, *save_warnings],
    )


@router.patch(
    "/{report_id}/rows/{bonus_result_id}",
    response_model=BonusResult,
    summary="Correct a misread value in one extracted row (before confirming the calculation)",
)
def correct_row(
    report_id: str,
    bonus_result_id: str,
    correction: RowCorrection,
    current_user: CurrentUser = Depends(get_current_user),
    db: Client = Depends(get_db),
) -> BonusResult:
    with report_busy_guard(report_id, "row save"):
        report = get_report_or_404(db, current_user.id, report_id)
        assert_report_modifiable(db, current_user.id, report)
        row = apply_row_correction(db, current_user.id, report, bonus_result_id, correction)
        return to_bonus_result(row)


@router.post(
    "/{report_id}/validate",
    response_model=ValidationSummary,
    summary="Validate a report's extracted rows before bonus calculation",
)
def validate_report(
    report_id: str,
    current_user: CurrentUser = Depends(get_current_user),
    db: Client = Depends(get_db),
) -> ValidationSummary:
    with report_busy_guard(report_id, "validation"):
        return _validate(db, current_user.id, report_id)


def _validate(db: Client, owner_id: str, report_id: str) -> ValidationSummary:
    report = get_report_or_404(db, owner_id, report_id)
    if report.get("status") == "completed":
        # Validating a completed report reopens it, which is only safe while
        # no newer report depends on its carry-forward balances.
        assert_report_modifiable(db, owner_id, report)

    rows = get_bonus_results_for_report(db, owner_id, report_id)
    raw_rows = [bonus_result_row_to_raw(row) for row in rows]
    result = validate_records(raw_rows, default_row_reference)

    if not raw_rows or not result.valid_records:
        new_status = "failed"
    else:
        new_status = "validated"

    update_report_status(db, owner_id, report_id, new_status)

    return ValidationSummary(
        report_id=report_id,
        status=new_status,
        total_input_records=len(raw_rows),
        valid_count=len(result.valid_records),
        invalid_count=len(result.invalid_records),
        valid_records=result.valid_records,
        invalid_records=result.invalid_records,
    )
