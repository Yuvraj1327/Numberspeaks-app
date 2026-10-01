"""
Supabase persistence for uploaded reports and their extracted rows.

Keeps every Supabase read/write for this feature in one place, on top of
the shared client from app/db/supabase_client.py. The route handler in
app/api/v1/endpoints/reports.py orchestrates these calls; it does not talk
to Supabase directly.
"""

import logging
import traceback
from datetime import datetime, timedelta, timezone
from typing import Any, Callable, Dict, Iterable, List, Optional, Tuple

from supabase import Client

from app.core.config import get_settings
from app.schemas.bonus import BonusResult
from app.schemas.report import ExtractedRecord

logger = logging.getLogger("numberspeaks")

REPORTS_BUCKET = "reports"

# reports.status values that mean a worker is (supposed to be) running.
ACTIVE_STATUSES = ("processing", "validating", "calculating")
# A stale report is re-claimed at most this many times before it is failed,
# so a report that crashes the worker can't be retried forever.
MAX_PROCESSING_ATTEMPTS = 3

# PostgREST returns at most this many rows per request (Supabase's default
# max-rows), so larger result sets must be read page by page.
READ_PAGE_SIZE = 1000
# Names per `users.name IN (...)` lookup — keeps the request URL short.
USER_LOOKUP_CHUNK = 100


def safe_error(exc: BaseException) -> str:
    """
    Short description of an exception that is safe to log: its type and
    database error code only. The message itself is left out because
    database errors can echo the offending row (phone numbers, amounts).
    """
    code = getattr(exc, "code", None)
    return f"{type(exc).__name__}" + (f" (code {code})" if code else "")


def safe_traceback(exc: BaseException) -> str:
    """Stack frames of an exception without its message (see safe_error)."""
    return "".join(traceback.format_tb(exc.__traceback__))


def _chunks(items: List[Any], size: int) -> Iterable[List[Any]]:
    for start in range(0, len(items), size):
        yield items[start:start + size]


def get_report(db: Client, report_id: str) -> Optional[dict]:
    res = db.table("reports").select("*").eq("id", report_id).limit(1).execute()
    return res.data[0] if res.data else None


def list_reports(db: Client, owner_id: Optional[str], limit: int) -> List[dict]:
    """Newest-first reports uploaded by `owner_id`; every account's when
    `owner_id` is None (admin view)."""
    query = db.table("reports").select(
        "id, owner_id, file_name, status, total_records, calculated_count, failed_count, "
        "uploaded_at, updated_at"
    )
    if owner_id is not None:
        query = query.eq("owner_id", owner_id)
    return query.order("uploaded_at", desc=True).limit(limit).execute().data


BONUS_RESULT_SELECT = (
    "id, report_id, user_id, casino_pts, sport_pts, third_party_pts, "
    "profit_loss, ptype, bonus_amount, calculation_status, created_at, "
    "users(id, name, level, whatsapp_number)"
)


def _read_all_pages(build_query: Callable[[], Any]) -> List[dict]:
    rows: List[dict] = []
    start = 0
    while True:
        page = build_query().range(start, start + READ_PAGE_SIZE - 1).execute().data
        rows.extend(page)
        if len(page) < READ_PAGE_SIZE:
            return rows
        start += READ_PAGE_SIZE


def get_bonus_results_for_report(
    db: Client, report_id: str, include_whatsapp: bool = False
) -> List[dict]:
    """
    Returns this report's extracted rows, each joined with its user's
    name and level — i.e. exactly the data Step 3 saved, reassembled into
    the same shape the PDF had. Reads every row regardless of report size
    (one request per 1000 rows).

    With `include_whatsapp=True` each row also carries its send attempts
    under "whatsapp_messages", fetched in the same request (see
    latest_whatsapp_status_of_row) instead of one lookup per row.
    """
    select = BONUS_RESULT_SELECT
    if include_whatsapp:
        select += ", whatsapp_messages(status, created_at)"

    return _read_all_pages(
        lambda: db.table("bonus_results")
        .select(select)
        .eq("report_id", report_id)
        .order("created_at")
        .order("id")
    )


def latest_whatsapp_status_of_row(row: dict) -> Optional[str]:
    """Status of the newest WhatsApp attempt embedded in a row fetched with
    include_whatsapp=True, or None if no attempt has been made."""
    messages = row.get("whatsapp_messages") or []
    if not messages:
        return None
    return max(messages, key=lambda m: m.get("created_at") or "").get("status")


def get_bonus_result_for_user(db: Client, report_id: str, user_id: str) -> Optional[dict]:
    """A single user's bonus_results row within one report."""
    res = (
        db.table("bonus_results")
        .select(BONUS_RESULT_SELECT)
        .eq("report_id", report_id)
        .eq("user_id", user_id)
        .limit(1)
        .execute()
    )
    return res.data[0] if res.data else None


def _write_batches(
    items: List[Any],
    write_many: Callable[[List[Any]], None],
    write_one: Callable[[Any], None],
    heartbeat: Optional[Callable[[], None]] = None,
) -> List[Any]:
    """
    Writes `items` in batches of DB_BATCH_SIZE, one request per batch.
    If a batch is rejected, its items are retried one by one so a single bad
    row costs only itself, not the batch. Returns the items that could not
    be written.
    """
    failed: List[Any] = []
    for chunk in _chunks(items, get_settings().DB_BATCH_SIZE):
        try:
            write_many(chunk)
        except Exception as exc:  # noqa: BLE001
            logger.warning(
                "Bulk write of %d rows failed (%s); retrying row by row",
                len(chunk), safe_error(exc),
            )
            for item in chunk:
                try:
                    write_one(item)
                except Exception as item_exc:  # noqa: BLE001
                    logger.warning("Single-row write failed: %s", safe_error(item_exc))
                    failed.append(item)
        if heartbeat:
            heartbeat()
    return failed


def bulk_update_bonus_results(
    db: Client,
    changes: List[dict],
    heartbeat: Optional[Callable[[], None]] = None,
) -> List[dict]:
    """
    Updates bonus_results rows in bulk. Each change is
    {"id", "report_id", "user_id", "calculation_status"[, "bonus_amount"]};
    all changes in one call must have the same keys. Implemented as an
    upsert on the primary key — only the columns given are written, and
    report_id/user_id are included solely because the insert half of an
    upsert needs them (the rows always exist already, so it never inserts).
    Returns the changes that could not be saved.
    """
    def write(chunk: List[dict]) -> None:
        db.table("bonus_results").upsert(chunk, on_conflict="id").execute()

    return _write_batches(changes, write, lambda item: write([item]), heartbeat)


def bonus_result_row_to_raw(row: dict) -> dict:
    """
    Reshapes a joined bonus_results+users row back into the report's 9
    columns, for re-running through the same validator Step 4 uses. Keeps
    the row's own id under a private key so callers can trace back to it
    without that id leaking into any user-facing 'raw' output.
    """
    user = row.get("users") or {}
    return {
        "no": None,  # not persisted — it's the PDF's own row number, not a DB concept
        "user_name": user.get("name"),
        "whatsapp_number": user.get("whatsapp_number"),
        "level": user.get("level"),
        "casino_pts": row.get("casino_pts"),
        "sport_pts": row.get("sport_pts"),
        "third_party_pts": row.get("third_party_pts"),
        "profit_loss": row.get("profit_loss"),
        "ptype": row.get("ptype"),
        "source_page": None,
        "_bonus_result_id": row.get("id"),
    }


def get_latest_whatsapp_status(db: Client, bonus_result_id: str) -> Optional[str]:
    """
    The most recent WhatsApp send attempt's status for one bonus_results
    row ('sent' or 'failed' — 'pending' rows are never left behind by
    whatsapp_service.py), or None if no attempt has been made yet.
    Powers the admin "WhatsApp Status" column (see to_bonus_result).
    """
    res = (
        db.table("whatsapp_messages")
        .select("status, created_at")
        .eq("bonus_result_id", bonus_result_id)
        .order("created_at", desc=True)
        .limit(1)
        .execute()
    )
    return res.data[0]["status"] if res.data else None


def default_row_reference(raw: dict, index: int) -> str:
    name = raw.get("user_name") or "unknown user"
    record_id = raw.get("_bonus_result_id")
    return f"user={name!r}, bonus_result_id={record_id}" if record_id else f"row {index + 1}, user={name!r}"


def to_bonus_result(row: dict, whatsapp_status: Optional[str] = None) -> BonusResult:
    """
    Converts one joined bonus_results+users row into the API schema.

    `whatsapp_status` is passed in by the caller (rather than looked up
    here) because callers differ: right after a fresh calculation no send
    has happened yet, so it's correctly left as the default "not_sent";
    the /results endpoints look it up per row via
    get_latest_whatsapp_status() before calling this.
    """
    user = row.get("users") or {}
    return BonusResult(
        bonus_result_id=row["id"],
        report_id=row["report_id"],
        user_id=row.get("user_id") or user.get("id"),
        user_name=user.get("name", ""),
        whatsapp_number=user.get("whatsapp_number"),
        level=user.get("level"),
        casino_pts=row.get("casino_pts", 0.0),
        sport_pts=row.get("sport_pts", 0.0),
        third_party_pts=row.get("third_party_pts", 0.0),
        profit_loss=row.get("profit_loss", 0.0),
        ptype=row.get("ptype"),
        bonus_amount=row.get("bonus_amount"),
        calculation_status=row.get("calculation_status") or "pending",
        whatsapp_status=whatsapp_status or "not_sent",
        created_at=row.get("created_at"),
    )


def create_report(db: Client, report_id: str, file_name: str, file_path: str, owner_id: str) -> dict:
    """Inserts the reports row (status 'uploaded') for a file that has
    already been given its storage path. `owner_id` is the authenticated
    account that uploaded it; every later access is checked against it."""
    res = (
        db.table("reports")
        .insert({
            "id": report_id,
            "owner_id": owner_id,
            "file_name": file_name,
            "file_path": file_path,
            "status": "uploaded",
        })
        .execute()
    )
    return res.data[0]


def delete_report(db: Client, report: dict) -> None:
    """
    Permanently deletes a report: its PDF in storage, then the report row,
    which cascades to its extracted rows, bonus results and WhatsApp send
    history. People (the `users` rows) are kept — they may also appear in
    the account's other reports. The file goes first: if it can't be
    removed the row stays and the delete can simply be retried, instead of
    leaving an unreachable file behind.
    """
    file_path = report.get("file_path")
    if file_path:
        db.storage.from_(REPORTS_BUCKET).remove([file_path])
    db.table("reports").delete().eq("id", report["id"]).execute()


def update_report_status(db: Client, report_id: str, status: str) -> None:
    db.table("reports").update({"status": status}).eq("id", report_id).execute()


def update_report(db: Client, report_id: str, **fields: Any) -> None:
    db.table("reports").update(fields).eq("id", report_id).execute()


def _parse_timestamp(value: Optional[str]) -> Optional[datetime]:
    if not value:
        return None
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None
    return parsed if parsed.tzinfo else parsed.replace(tzinfo=timezone.utc)


def is_report_stale(report: dict) -> bool:
    """True if the report is in a not-yet-final state but hasn't changed for
    PROCESSING_STALE_SECONDS — its worker is presumed gone. Unknown or
    missing timestamps count as not stale."""
    if report.get("status") not in ("uploaded", *ACTIVE_STATUSES):
        return False
    updated_at = _parse_timestamp(report.get("updated_at"))
    if updated_at is None:
        return False
    age = datetime.now(timezone.utc) - updated_at
    return age > timedelta(seconds=get_settings().PROCESSING_STALE_SECONDS)


def claim_report(db: Client, report_id: str) -> Optional[dict]:
    """
    Atomically takes ownership of a report for processing. Returns the
    claimed report row to exactly one caller; everyone else (a duplicate
    request, a second worker) gets None and must not process it.

    A report is claimable when it is 'uploaded', or when it is in a
    processing state but stale (its worker died). The claim is a
    compare-and-swap on (status, attempts), so two callers racing on the
    same report cannot both win.
    """
    report = get_report(db, report_id)
    if report is None:
        return None

    status = report.get("status")
    attempts = report.get("attempts") or 0

    if status != "uploaded":
        if status not in ACTIVE_STATUSES or not is_report_stale(report):
            return None
        if attempts >= MAX_PROCESSING_ATTEMPTS:
            logger.error("Report %s abandoned after %d attempts; marking failed", report_id, attempts)
            update_report(
                db, report_id, status="failed",
                error_message="Processing did not finish after several attempts. Please upload the report again.",
            )
            return None

    res = (
        db.table("reports")
        .update({"status": "processing", "attempts": attempts + 1, "error_message": None})
        .eq("id", report_id)
        .eq("status", status)
        .eq("attempts", attempts)
        .execute()
    )
    return res.data[0] if res.data else None


def upload_pdf_to_storage(db: Client, report_id: str, file_name: str, file_bytes: bytes) -> str:
    """
    Uploads the raw PDF to Supabase Storage and returns its storage path.
    Requires a bucket named 'reports' to already exist (see
    supabase/storage_setup.sql).
    """
    storage_path = storage_path_for(report_id, file_name)
    db.storage.from_(REPORTS_BUCKET).upload(
        storage_path,
        file_bytes,
        {"content-type": "application/pdf"},
    )
    return storage_path


def storage_path_for(report_id: str, file_name: str) -> str:
    return f"{report_id}/{file_name}"


def download_pdf_from_storage(db: Client, file_path: str) -> bytes:
    return db.storage.from_(REPORTS_BUCKET).download(file_path)


def _in_filter_value(values: List[str]) -> str:
    """PostgREST `in.(...)` value with every item double-quoted, so names
    containing commas, parentheses, quotes or colons match exactly."""
    quoted = ('"' + v.replace("\\", "\\\\").replace('"', '\\"') + '"' for v in values)
    return "(" + ",".join(quoted) + ")"


def ensure_users(
    db: Client,
    first_record_by_name: Dict[str, ExtractedRecord],
    owner_id: Optional[str] = None,
    heartbeat: Optional[Callable[[], None]] = None,
) -> Tuple[Dict[str, str], List[str]]:
    """
    Bulk equivalent of "find the user by exact name, or create them".

    Matching by name (rather than generating a new user per report) keeps
    the same person's bonus history linked across report uploads. Matching
    is limited to users created by the same account (`owner_id`), so one
    account's upload can never reuse, read or overwrite another account's
    recipients (their level / WhatsApp number). When a match is found and the report shows a different level or WhatsApp
    number, that field is updated to the report's latest value.

    Costs one lookup per USER_LOOKUP_CHUNK names, one upsert per batch of
    changed users, and one insert per batch of new users — not 2-3 requests
    per user. Returns ({name: user_id}, warnings); names whose user could
    not be created are absent from the map and explained in the warnings.
    """
    names = list(first_record_by_name)
    existing: Dict[str, dict] = {}
    for chunk in _chunks(names, USER_LOOKUP_CHUNK):
        query = (
            db.table("users")
            .select("id, name, level, whatsapp_number")
            .filter("name", "in", _in_filter_value(chunk))
        )
        # Reports without an owner (uploaded before ownership existed) keep
        # using the users that likewise have no owner.
        query = query.eq("owner_id", owner_id) if owner_id else query.filter("owner_id", "is", "null")
        res = query.order("created_at").execute()
        for user in res.data:
            existing.setdefault(user["name"], user)  # oldest wins if names repeat
        if heartbeat:
            heartbeat()

    user_ids: Dict[str, str] = {name: user["id"] for name, user in existing.items()}
    warnings: List[str] = []

    # Existing users whose level / WhatsApp number changed in this report.
    changed: List[dict] = []
    for name, user in existing.items():
        record = first_record_by_name[name]
        level = record.level if record.level and user.get("level") != record.level else user.get("level")
        number = (
            record.whatsapp_number
            if record.whatsapp_number and user.get("whatsapp_number") != record.whatsapp_number
            else user.get("whatsapp_number")
        )
        if level != user.get("level") or number != user.get("whatsapp_number"):
            changed.append({"id": user["id"], "name": name, "level": level, "whatsapp_number": number})

    def update_many(chunk: List[dict]) -> None:
        db.table("users").upsert(chunk, on_conflict="id").execute()

    for failed in _write_batches(changed, update_many, lambda item: update_many([item]), heartbeat):
        warnings.append(f"Could not update level/WhatsApp number for '{failed['name']}'")

    # New users.
    to_create = [
        {"name": name, "level": rec.level, "whatsapp_number": rec.whatsapp_number, "owner_id": owner_id}
        for name, rec in first_record_by_name.items()
        if name not in existing
    ]

    def insert_many(chunk: List[dict]) -> None:
        for user in db.table("users").insert(chunk).execute().data:
            user_ids[user["name"]] = user["id"]

    for failed in _write_batches(to_create, insert_many, lambda item: insert_many([item]), heartbeat):
        warnings.append(f"Could not create user '{failed['name']}'")

    return user_ids, warnings


def save_extracted_records(
    db: Client,
    report_id: str,
    records: List[ExtractedRecord],
    owner_id: Optional[str] = None,
    heartbeat: Optional[Callable[[], None]] = None,
) -> Tuple[int, List[str]]:
    """
    Persists each extracted record as a bonus_results row, creating/reusing
    users as needed (in bulk — see ensure_users). bonus_amount is left null;
    calculation happens in its own stage.

    Returns (saved_count, warnings). A row that cannot be saved is recorded
    as a warning and skipped rather than failing the whole report, since
    the rest of the report may still be good data. Safe to run twice for
    the same report: rows are upserted on (report_id, user_id).
    """
    warnings: List[str] = []

    # One row per user per report (a DB constraint): the first occurrence
    # of a repeated name is kept, the rest are reported.
    first_by_name: Dict[str, ExtractedRecord] = {}
    for record in records:
        if record.user_name in first_by_name:
            warnings.append(
                f"Could not save row for '{record.user_name}' (page {record.source_page}): "
                "this user appears more than once in the report"
            )
        else:
            first_by_name[record.user_name] = record

    user_ids, user_warnings = ensure_users(db, first_by_name, owner_id, heartbeat)
    warnings.extend(user_warnings)

    # Explicit, strictly increasing created_at keeps the PDF's row order
    # when the rows are read back (a batch insert would give them all the
    # same timestamp).
    base_time = datetime.now(timezone.utc)
    rows: List[Tuple[ExtractedRecord, dict]] = []
    for record in first_by_name.values():
        user_id = user_ids.get(record.user_name)
        if user_id is None:
            continue  # the user failure was already reported above
        rows.append((record, {
            "report_id": report_id,
            "user_id": user_id,
            "casino_pts": record.casino_pts,
            "sport_pts": record.sport_pts,
            "third_party_pts": record.third_party_pts,
            "profit_loss": record.profit_loss,
            "ptype": record.ptype,
            "created_at": (base_time + timedelta(microseconds=len(rows))).isoformat(),
        }))

    def save_many(chunk: List[Tuple[ExtractedRecord, dict]]) -> None:
        db.table("bonus_results").upsert(
            [payload for _, payload in chunk], on_conflict="report_id,user_id"
        ).execute()

    failed = _write_batches(rows, save_many, lambda item: save_many([item]), heartbeat)
    for record, _ in failed:
        warnings.append(
            f"Could not save row for '{record.user_name}' (page {record.source_page})"
        )

    return len(rows) - len(failed), warnings
