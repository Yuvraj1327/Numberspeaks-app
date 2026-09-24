"""
Report upload, extraction, and validation endpoints.

Step 3 (upload): accept the PDF, extract its table data into structured
records, store the file and results. Step 4 (validate): re-check what was
extracted and stored, and gate the report's readiness for bonus
calculation. No bonus math, no WhatsApp — those are later steps.

Order of operations is deliberate: the file is validated and extracted
BEFORE anything touches Supabase. That way a bad upload (wrong type,
unreadable PDF) fails fast with a clear 4xx and never creates a database
row, and a Supabase outage is reported as its own distinct error rather
than being confused with a bad file.
"""

import logging

from fastapi import APIRouter, File, HTTPException, UploadFile, status

from app.db.supabase_client import SupabaseNotConfiguredError, get_supabase
from app.schemas.report import UploadReportResponse
from app.schemas.validation import ValidationSummary
from app.services.pdf_extractor import PdfExtractionError, extract_records_from_pdf
from app.services.reports_service import (
    bonus_result_row_to_raw,
    create_report,
    default_row_reference,
    get_bonus_results_for_report,
    get_report,
    save_extracted_records,
    update_report_file_path,
    update_report_status,
    upload_pdf_to_storage,
)
from app.services.validation import validate_records

logger = logging.getLogger("numberspeaks")

router = APIRouter(prefix="/reports", tags=["Reports"])

MAX_FILE_SIZE_BYTES = 20 * 1024 * 1024  # 20 MB — generous for an 8-page report.


@router.post("/upload", response_model=UploadReportResponse, summary="Upload and extract a report PDF")
async def upload_report(
    file: UploadFile = File(..., description="The 'Party Profit Loss' PDF report"),
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
            detail=f"Unexpected error while extracting the PDF: {exc}",
        ) from exc

    # --- 3. Connect to Supabase ------------------------------------------------
    try:
        db = get_supabase()
    except SupabaseNotConfiguredError as exc:
        raise HTTPException(status_code=status.HTTP_503_SERVICE_UNAVAILABLE, detail=str(exc)) from exc

    # --- 4. Create the report record, then store the file ----------------------
    try:
        report = create_report(db, filename)
        report_id = report["id"]
    except Exception as exc:  # noqa: BLE001
        logger.exception("Failed to create report record")
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail=f"Could not save report to the database: {exc}",
        ) from exc

    try:
        storage_path = upload_pdf_to_storage(db, report_id, filename, file_bytes)
        update_report_file_path(db, report_id, storage_path)
    except Exception as exc:  # noqa: BLE001
        logger.exception("Failed to upload PDF to storage for report %s", report_id)
        update_report_status(db, report_id, "failed")
        raise HTTPException(
            status_code=status.HTTP_502_BAD_GATEWAY,
            detail=(
                "The report was registered but the file could not be stored: "
                f"{exc}. Make sure the 'reports' Storage bucket exists "
                "(see supabase/storage_setup.sql)."
            ),
        ) from exc

    # --- 5. Save the extracted rows ---------------------------------------------
    saved_count, save_warnings = save_extracted_records(db, report_id, extraction.records)

    # "processing" = extracted and stored, awaiting validation (a later step).
    update_report_status(db, report_id, "processing")

    return UploadReportResponse(
        report_id=report_id,
        file_name=filename,
        status="processing",
        pages_processed=extraction.pages_processed,
        total_records=saved_count,
        records=extraction.records,
        warnings=[*extraction.warnings, *save_warnings],
    )


@router.post(
    "/{report_id}/validate",
    response_model=ValidationSummary,
    summary="Validate a report's extracted rows before bonus calculation",
)
async def validate_report(report_id: str) -> ValidationSummary:
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

    if report is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail=f"No report found with id {report_id}")

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
