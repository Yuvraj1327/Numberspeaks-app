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
from typing import List

from fastapi import APIRouter, Depends, File, HTTPException, UploadFile, status
from supabase import Client

from app.api.deps import CurrentUser, assert_report_modifiable, get_current_user, get_db, get_report_or_404
from app.schemas.bonus import BonusResult, RowCorrection
from app.schemas.report import ReportSummary, UploadReportResponse
from app.schemas.validation import ValidationSummary
from app.services.corrections_service import apply_row_correction
from app.services.pdf_extractor import PdfExtractionError, extract_records_from_pdf
from app.services.reports_service import (
    bonus_result_row_to_raw,
    create_report,
    default_row_reference,
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
async def list_my_reports(
    current_user: CurrentUser = Depends(get_current_user),
    db: Client = Depends(get_db),
) -> List[ReportSummary]:
    return [to_report_summary(row) for row in list_reports(db, current_user.id)]


@router.get("/{report_id}", response_model=ReportSummary, summary="Get one report")
async def get_one_report(
    report_id: str,
    current_user: CurrentUser = Depends(get_current_user),
    db: Client = Depends(get_db),
) -> ReportSummary:
    return to_report_summary(get_report_or_404(db, current_user.id, report_id))


@router.post("/upload", response_model=UploadReportResponse, summary="Upload and extract a report PDF")
async def upload_report(
    file: UploadFile = File(..., description="The 'Party Profit Loss' PDF report"),
    current_user: CurrentUser = Depends(get_current_user),
    db: Client = Depends(get_db),
) -> UploadReportResponse:
    owner_id = current_user.id

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
        report = create_report(db, owner_id, filename)
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

    return UploadReportResponse(
        report_id=report_id,
        file_name=filename,
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
async def correct_row(
    report_id: str,
    bonus_result_id: str,
    correction: RowCorrection,
    current_user: CurrentUser = Depends(get_current_user),
    db: Client = Depends(get_db),
) -> BonusResult:
    report = get_report_or_404(db, current_user.id, report_id)
    assert_report_modifiable(db, current_user.id, report)
    row = apply_row_correction(db, current_user.id, report, bonus_result_id, correction)
    return to_bonus_result(row)


@router.post(
    "/{report_id}/validate",
    response_model=ValidationSummary,
    summary="Validate a report's extracted rows before bonus calculation",
)
async def validate_report(
    report_id: str,
    current_user: CurrentUser = Depends(get_current_user),
    db: Client = Depends(get_db),
) -> ValidationSummary:
    owner_id = current_user.id
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
