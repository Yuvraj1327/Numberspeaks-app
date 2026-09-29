"""
Background processing of an uploaded report.

The upload endpoint only stores the PDF and creates the report row; the
work happens here, off the HTTP request, on a small fixed pool of worker
threads:

    uploaded -> processing (download + extract + save rows)
             -> validating -> calculating -> completed | failed

The report's `status` column is the only progress channel — the client
polls GET /reports/{id}/status. A slow client, a dropped connection or a
client-side timeout has no effect on a running job.

Safety properties:
- A job only starts after claim_report() wins an atomic compare-and-swap,
  so a report can never be processed twice at once.
- The pool size bounds concurrent jobs (memory), however many users upload.
- Every stage bumps the report row, so a job whose worker died (restart,
  crash) stops changing and is detected as abandoned and resumed — see
  resume_if_abandoned().
- Logs carry report ids, counts and error types only: never PDF contents,
  names, phone numbers or amounts.
"""

import logging
import time
from concurrent.futures import ThreadPoolExecutor
from threading import Lock
from typing import List, Optional, Set

from supabase import Client

from app.core.config import get_settings
from app.db.supabase_client import SupabaseNotConfiguredError, get_supabase
from app.services.bonus_calculator import BonusFormulaNotConfiguredError
from app.services.bonus_service import run_bonus_calculation
from app.services.pdf_extractor import PdfExtractionError, extract_records_from_pdf
from app.services.reports_service import (
    bonus_result_row_to_raw,
    claim_report,
    default_row_reference,
    download_pdf_from_storage,
    get_bonus_results_for_report,
    is_report_stale,
    safe_error,
    safe_traceback,
    save_extracted_records,
    update_report,
)
from app.services.validation import validate_records

logger = logging.getLogger("numberspeaks")

# Warnings are stored on the report row; cap them so a pathological PDF
# can't make that row (and every status poll) huge.
MAX_STORED_WARNINGS = 200
HEARTBEAT_INTERVAL_SECONDS = 15.0

_executor: Optional[ThreadPoolExecutor] = None
_pending: Set[str] = set()  # report ids queued or running in this process
_lock = Lock()


class _ReportFailed(Exception):
    """A report-level failure with a message that is safe to show the user."""


def submit_report(report_id: str) -> bool:
    """Queues a report for background processing. Returns False if it is
    already queued or running in this process."""
    global _executor
    with _lock:
        if report_id in _pending:
            return False
        if _executor is None:
            _executor = ThreadPoolExecutor(
                max_workers=get_settings().MAX_CONCURRENT_REPORT_JOBS,
                thread_name_prefix="report-job",
            )
        _pending.add(report_id)
        _executor.submit(_run_job, report_id)
    return True


def resume_if_abandoned(report: dict) -> bool:
    """
    Re-queues a report whose worker has evidently died (see
    is_report_stale). Called when its status is requested, so a job lost to
    a restart is picked up again as soon as anyone looks at it.
    """
    if is_report_stale(report):
        logger.warning("Report %s looks abandoned in status %r; resuming", report["id"], report.get("status"))
        return submit_report(report["id"])
    return False


def _run_job(report_id: str) -> None:
    try:
        process_report(report_id)
    except Exception as exc:  # noqa: BLE001
        logger.error("Report job %s crashed: %s\n%s", report_id, safe_error(exc), safe_traceback(exc))
    finally:
        with _lock:
            _pending.discard(report_id)


class _Heartbeat:
    """Throttled progress writes. Each write also bumps reports.updated_at,
    which is what marks the job as alive."""

    def __init__(self, db: Client, report_id: str) -> None:
        self._db = db
        self._report_id = report_id
        self._last = time.monotonic()
        self.pages_processed = 0

    def mark(self) -> None:
        self._last = time.monotonic()

    def tick(self) -> None:
        if time.monotonic() - self._last < HEARTBEAT_INTERVAL_SECONDS:
            return
        self.mark()
        try:
            update_report(self._db, self._report_id, pages_processed=self.pages_processed)
        except Exception as exc:  # noqa: BLE001
            # Progress is best-effort; never fail the job over it.
            logger.warning("Heartbeat for report %s failed: %s", self._report_id, safe_error(exc))

    def on_page_done(self, pages_done: int, _total_pages: int) -> None:
        self.pages_processed = pages_done
        self.tick()


def _cap_warnings(warnings: List[str]) -> List[str]:
    if len(warnings) <= MAX_STORED_WARNINGS:
        return warnings
    return [*warnings[:MAX_STORED_WARNINGS], f"...and {len(warnings) - MAX_STORED_WARNINGS} more warnings"]


def _set_stage(db: Client, report_id: str, beat: _Heartbeat, status: str, **fields) -> None:
    update_report(db, report_id, status=status, **fields)
    beat.mark()


def process_report(report_id: str) -> None:
    """Runs the whole pipeline for one report. Blocking; runs in a worker."""
    try:
        db = get_supabase()
    except SupabaseNotConfiguredError:
        logger.error("Cannot process report %s: Supabase is not configured", report_id)
        return

    try:
        report = claim_report(db, report_id)
    except Exception as exc:  # noqa: BLE001
        logger.error("Could not claim report %s: %s", report_id, safe_error(exc))
        return

    if report is None:
        logger.info("Report %s is not claimable (already processing or finished); skipping", report_id)
        return

    started = time.monotonic()
    logger.info("Report %s: processing started (attempt %s)", report_id, report.get("attempts"))

    try:
        _run_pipeline(db, report_id, report["file_path"])
    except _ReportFailed as exc:
        _fail(db, report_id, str(exc))
    except Exception as exc:  # noqa: BLE001
        logger.error("Report %s failed unexpectedly: %s\n%s", report_id, safe_error(exc), safe_traceback(exc))
        _fail(db, report_id, "Processing failed unexpectedly. Please try uploading the report again.")
    else:
        logger.info("Report %s: processing finished in %.1fs", report_id, time.monotonic() - started)


def _fail(db: Client, report_id: str, message: str) -> None:
    logger.warning("Report %s: marked failed", report_id)
    try:
        update_report(db, report_id, status="failed", error_message=message)
    except Exception as exc:  # noqa: BLE001
        # Leaving the status as-is is safe: it goes stale and is retried.
        logger.error("Could not mark report %s failed: %s", report_id, safe_error(exc))


def _run_pipeline(db: Client, report_id: str, file_path: str) -> None:
    beat = _Heartbeat(db, report_id)

    # --- extraction (status: processing) --------------------------------------
    file_bytes = download_pdf_from_storage(db, file_path)
    try:
        extraction = extract_records_from_pdf(file_bytes, on_page_done=beat.on_page_done)
    except PdfExtractionError as exc:
        logger.warning("Report %s: extraction failed", report_id)
        raise _ReportFailed(str(exc)) from exc
    finally:
        del file_bytes  # large PDFs: don't hold the bytes through the DB stages

    logger.info(
        "Report %s: extracted %d records from %d pages",
        report_id, len(extraction.records), extraction.pages_processed,
    )

    saved_count, save_warnings = save_extracted_records(
        db, report_id, extraction.records, heartbeat=beat.tick
    )
    warnings = _cap_warnings([*extraction.warnings, *save_warnings])
    if saved_count == 0:
        raise _ReportFailed("None of the extracted rows could be saved.")

    # --- validation ----------------------------------------------------------
    _set_stage(
        db, report_id, beat, "validating",
        pages_processed=extraction.pages_processed, total_records=saved_count, warnings=warnings,
    )
    rows = get_bonus_results_for_report(db, report_id)
    validation = validate_records([bonus_result_row_to_raw(row) for row in rows], default_row_reference)
    logger.info(
        "Report %s: validated %d rows (%d valid, %d invalid)",
        report_id, len(rows), len(validation.valid_records), len(validation.invalid_records),
    )
    if not rows or not validation.valid_records:
        raise _ReportFailed("No valid rows were found in this report.")

    # --- bonus calculation ---------------------------------------------------
    _set_stage(db, report_id, beat, "calculating")
    try:
        calculated_count, _results, errors = run_bonus_calculation(db, rows, heartbeat=beat.tick)
    except BonusFormulaNotConfiguredError as exc:
        raise _ReportFailed(str(exc)) from exc

    logger.info(
        "Report %s: calculated %d bonuses, %d rows with errors",
        report_id, calculated_count, len(errors),
    )

    if calculated_count == 0:
        raise _ReportFailed("No bonus could be calculated for this report.")

    update_report(
        db, report_id,
        status="completed", calculated_count=calculated_count, failed_count=len(errors),
    )
