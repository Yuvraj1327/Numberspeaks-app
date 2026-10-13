"""
Supabase persistence for uploaded reports and their extracted rows.

Keeps every Supabase read/write for reports and results in one place, on top
of the shared client from app/db/supabase_client.py. Route handlers
orchestrate these calls; they do not talk to Supabase directly.

OWNERSHIP: every function takes `owner_id` (the verified admin's id from
app/core/auth.py) and includes it in every query. The service-role client
bypasses Row Level Security, so this filtering is what keeps one admin's
reports/users/results invisible to another. A row that exists but belongs to
someone else is indistinguishable from one that doesn't exist (callers get
`None` / an empty list, which routes turn into 404).
"""

import logging
import re
from typing import Callable, Iterable, List, Optional, Tuple
from uuid import UUID

from supabase import Client

from app.schemas.bonus import BonusResult
from app.schemas.report import ExtractedRecord, ReportSummary

logger = logging.getLogger("numberspeaks")

REPORTS_BUCKET = "reports"

# PostgREST returns at most 1000 rows per request by default, so any list
# that can exceed that (a report with many users) must be read page by page
# or it would be silently truncated.
PAGE_SIZE = 1000
INSERT_CHUNK = 200


# --- small helpers ----------------------------------------------------------


def is_valid_uuid(value: object) -> bool:
    """True for a well-formed UUID string. Used so a garbage id in a URL is a
    clean 404 instead of a database 'invalid input syntax for type uuid'
    error surfacing as a 503."""
    try:
        UUID(str(value))
        return True
    except (ValueError, AttributeError, TypeError):
        return False


def fetch_all(build_page: Callable[[int, int], object]) -> List[dict]:
    """Reads every row of a query by paging with .range(start, end).

    `build_page(start, end)` must return an *executed* response for that
    inclusive range and the query must have a stable order.
    """
    rows: List[dict] = []
    start = 0
    while True:
        response = build_page(start, start + PAGE_SIZE - 1)
        batch = response.data or []
        rows.extend(batch)
        if len(batch) < PAGE_SIZE:
            return rows
        start += PAGE_SIZE


def chunked(items: List, size: int) -> Iterable[List]:
    for index in range(0, len(items), size):
        yield items[index : index + size]


def is_unique_violation(exc: Exception) -> bool:
    """True if a Supabase/PostgREST error is a unique-constraint violation
    (Postgres code 23505)."""
    code = getattr(exc, "code", None)
    text = str(exc).lower()
    return code == "23505" or "23505" in text or "duplicate key" in text


def safe_error(exc: BaseException) -> str:
    """A log-safe description of an exception: its type and database error
    code only. PostgREST error text can quote the failing row (names, phone
    numbers, amounts), so the message itself is never logged."""
    code = getattr(exc, "code", None)
    return f"{type(exc).__name__}" + (f" (code {code})" if code else "")


def _f(value: object) -> Optional[float]:
    """numeric column -> float, keeping NULL as None."""
    if value is None:
        return None
    return float(value)


# --- reports ------------------------------------------------------------------


def get_report(db: Client, owner_id: str, report_id: str) -> Optional[dict]:
    if not is_valid_uuid(report_id):
        return None
    res = (
        db.table("reports")
        .select("*")
        .eq("owner_id", owner_id)
        .eq("id", report_id)
        .limit(1)
        .execute()
    )
    return res.data[0] if res.data else None


def list_reports(db: Client, owner_id: str) -> List[dict]:
    """All of this admin's reports, latest period first (see report_sort_key)."""
    rows = fetch_all(
        lambda a, b: db.table("reports")
        .select("*")
        .eq("owner_id", owner_id)
        .order("uploaded_at", desc=True)
        .order("id")
        .range(a, b)
        .execute()
    )
    return sorted(rows, key=report_sort_key, reverse=True)


def report_sort_key(row: dict) -> Tuple[str, str]:
    """Chronological position of a report: its period start (a week the admin
    chose) or, for legacy reports without a period, the upload date. Carry-
    forward follows this order, NOT upload order, so weeks can be imported
    out of sequence without breaking balances."""
    uploaded = row.get("uploaded_at") or ""
    return (str(row.get("period_start") or uploaded[:10]), uploaded)


def to_report_summary(row: dict) -> ReportSummary:
    return ReportSummary(
        report_id=row["id"],
        period_start=row.get("period_start"),
        period_end=row.get("period_end"),
        file_name=row.get("file_name", ""),
        status=row.get("status", ""),
        uploaded_at=row.get("uploaded_at"),
        calculated_at=row.get("calculated_at"),
        user_count=row.get("user_count"),
        payable_user_count=row.get("payable_user_count"),
        total_payable=_f(row.get("total_payable")),
    )


def create_report(
    db: Client,
    owner_id: str,
    file_name: str,
    period_start: Optional[str] = None,
    period_end: Optional[str] = None,
) -> dict:
    """Inserts the initial reports row. file_path is filled in once the
    file has actually been stored (see update_report_file_path)."""
    row = {"owner_id": owner_id, "file_name": file_name, "file_path": "", "status": "uploaded"}
    if period_start and period_end:
        row["period_start"] = period_start
        row["period_end"] = period_end
    return db.table("reports").insert(row).execute().data[0]


def find_period_conflicts(
    db: Client, owner_id: str, period_start: str, period_end: str
) -> Tuple[Optional[dict], Optional[dict]]:
    """(identical-period report, other overlapping report) for this admin."""
    same: Optional[dict] = None
    overlap: Optional[dict] = None
    for r in list_reports(db, owner_id):
        start, end = r.get("period_start"), r.get("period_end")
        if not (start and end):
            continue
        if start == period_start and end == period_end:
            same = r
        elif start <= period_end and end >= period_start:
            overlap = overlap or r
    return same, overlap


def update_report_file_path(db: Client, owner_id: str, report_id: str, file_path: str) -> None:
    db.table("reports").update({"file_path": file_path}).eq("owner_id", owner_id).eq("id", report_id).execute()


def update_report_status(db: Client, owner_id: str, report_id: str, status: str) -> None:
    db.table("reports").update({"status": status}).eq("owner_id", owner_id).eq("id", report_id).execute()


def update_report_summary(db: Client, owner_id: str, report_id: str, fields: dict) -> None:
    db.table("reports").update(fields).eq("owner_id", owner_id).eq("id", report_id).execute()


def first_later_completed_report(db: Client, owner_id: str, report: dict) -> Optional[dict]:
    """The earliest report chronologically AFTER this one (by period, see
    report_sort_key) that has already been calculated, or None.

    Carry-forward balances flow from one period to the next, so recalculating,
    reopening or deleting an older report once a newer one is calculated would
    leave the newer report's "previous balance" stale. Callers block that case.
    """
    mine = report_sort_key(report)
    later = [
        r
        for r in list_reports(db, owner_id)
        if r.get("status") == "completed" and r["id"] != report["id"] and report_sort_key(r) > mine
    ]
    later.sort(key=report_sort_key)
    return later[0] if later else None


def later_report_is_completed(db: Client, owner_id: str, report: dict) -> bool:
    return first_later_completed_report(db, owner_id, report) is not None


def delete_report(db: Client, owner_id: str, report: dict) -> bool:
    """
    Deletes one of this admin's reports and everything that belongs to it.

    The reports row is deleted first, in a single statement, so the database's
    ON DELETE CASCADE removes its bonus_results (and their WhatsApp records),
    referral_entries and calculation_history atomically — either all of it goes
    or, on an error, nothing does. The explicit deletes after it are scoped to
    the same owner and report and only mop up if a cascade is missing.
    Users are never touched: they are shared with the admin's other reports.

    The stored PDF is removed last and best-effort: the report is already gone
    by then, and a leftover file is harmless. Returns False if that file could
    not be removed.
    """
    report_id = report["id"]
    db.table("reports").delete().eq("owner_id", owner_id).eq("id", report_id).execute()
    for table in ("calculation_history", "referral_entries", "bonus_results"):
        db.table(table).delete().eq("owner_id", owner_id).eq("report_id", report_id).execute()

    file_path = report.get("file_path") or ""
    # Only ever remove a file stored under this report's own folder.
    if not file_path.startswith(f"{report_id}/"):
        return True
    try:
        db.storage.from_(REPORTS_BUCKET).remove([file_path])
        return True
    except Exception as exc:  # noqa: BLE001
        logger.warning("Report %s deleted but its PDF could not be removed: %s", report_id, safe_error(exc))
        return False


def upload_pdf_to_storage(db: Client, report_id: str, file_name: str, file_bytes: bytes) -> str:
    """
    Uploads the raw PDF to Supabase Storage and returns its storage path.
    Requires a bucket named 'reports' to already exist (see
    supabase/storage_setup.sql). The path starts with the report's own
    (unguessable) uuid, and the bucket is private.
    """
    storage_path = f"{report_id}/{file_name}"
    db.storage.from_(REPORTS_BUCKET).upload(
        storage_path,
        file_bytes,
        {"content-type": "application/pdf"},
    )
    return storage_path


# --- bonus_results ----------------------------------------------------------------

BONUS_RESULT_SELECT = (
    "id, report_id, user_id, casino_pts, sport_pts, third_party_pts, "
    "profit_loss, ptype, bonus_amount, calculation_status, created_at, "
    "personal_rate_used, personal_adjustment, referral_adjustment, "
    "previous_balance, final_balance, payable_bonus, carry_forward_balance, "
    "calculated_at, whatsapp_send_status, whatsapp_send_error, whatsapp_sent_at, "
    "users(id, name, level, whatsapp_number)"
)


def get_bonus_results_for_report(db: Client, owner_id: str, report_id: str) -> List[dict]:
    """
    Returns this report's rows, each joined with its user's name, level and
    WhatsApp number — exactly the data extraction saved (plus any later
    corrections and calculation results), reassembled into the shape the
    PDF had. Reads every page of results so a large report is never cut off.
    """
    if not is_valid_uuid(report_id):
        return []
    return fetch_all(
        lambda a, b: db.table("bonus_results")
        .select(BONUS_RESULT_SELECT)
        .eq("owner_id", owner_id)
        .eq("report_id", report_id)
        .order("id")
        .range(a, b)
        .execute()
    )


def get_bonus_result_for_user(db: Client, owner_id: str, report_id: str, user_id: str) -> Optional[dict]:
    """A single user's bonus_results row within one report."""
    if not (is_valid_uuid(report_id) and is_valid_uuid(user_id)):
        return None
    res = (
        db.table("bonus_results")
        .select(BONUS_RESULT_SELECT)
        .eq("owner_id", owner_id)
        .eq("report_id", report_id)
        .eq("user_id", user_id)
        .limit(1)
        .execute()
    )
    return res.data[0] if res.data else None


def get_bonus_result_by_id(db: Client, owner_id: str, report_id: str, bonus_result_id: str) -> Optional[dict]:
    if not (is_valid_uuid(report_id) and is_valid_uuid(bonus_result_id)):
        return None
    res = (
        db.table("bonus_results")
        .select(BONUS_RESULT_SELECT)
        .eq("owner_id", owner_id)
        .eq("report_id", report_id)
        .eq("id", bonus_result_id)
        .limit(1)
        .execute()
    )
    return res.data[0] if res.data else None


def update_calculation_status(db: Client, owner_id: str, bonus_result_id: str, status: str) -> None:
    """
    Marks a row's calculation_status directly, without touching its amounts —
    used for rows that failed validation (status='invalid') so the failure
    is saved durably instead of only reported in-memory.
    """
    db.table("bonus_results").update({"calculation_status": status}).eq("owner_id", owner_id).eq(
        "id", bonus_result_id
    ).execute()


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


def default_row_reference(raw: dict, index: int) -> str:
    name = raw.get("user_name") or "unknown user"
    record_id = raw.get("_bonus_result_id")
    return f"user={name!r}, bonus_result_id={record_id}" if record_id else f"row {index + 1}, user={name!r}"


def to_bonus_result(row: dict) -> BonusResult:
    """Converts one joined bonus_results+users row into the API schema."""
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
        bonus_amount=_f(row.get("bonus_amount")),
        calculation_status=row.get("calculation_status") or "pending",
        personal_rate_used=_f(row.get("personal_rate_used")),
        personal_adjustment=_f(row.get("personal_adjustment")),
        referral_adjustment=_f(row.get("referral_adjustment")),
        previous_balance=_f(row.get("previous_balance")),
        final_balance=_f(row.get("final_balance")),
        payable_bonus=_f(row.get("payable_bonus")),
        carry_forward_balance=_f(row.get("carry_forward_balance")),
        calculated_at=row.get("calculated_at"),
        send_status=row.get("whatsapp_send_status") or "pending",
        send_error=row.get("whatsapp_send_error"),
        sent_at=row.get("whatsapp_sent_at"),
        created_at=row.get("created_at"),
    )


# --- users (casino users, per admin) ---------------------------------------------


def get_or_create_user(
    db: Client,
    owner_id: str,
    name: str,
    level: Optional[str] = None,
    whatsapp_number: Optional[str] = None,
) -> str:
    """
    Finds this admin's user by exact name, or creates one.

    Matching by name keeps the same person's balance and history linked
    across report uploads. A level from the report updates the stored level.
    A WhatsApp number from the PDF only FILLS AN EMPTY number — it never
    overwrites one the admin saved by hand.
    """
    existing = (
        db.table("users")
        .select("id, level, whatsapp_number")
        .eq("owner_id", owner_id)
        .eq("name", name)
        .limit(1)
        .execute()
    )

    if existing.data:
        user = existing.data[0]
        updates = {}
        if level and user.get("level") != level:
            updates["level"] = level
        if whatsapp_number and not user.get("whatsapp_number"):
            updates["whatsapp_number"] = whatsapp_number
        if updates:
            db.table("users").update(updates).eq("owner_id", owner_id).eq("id", user["id"]).execute()
        return user["id"]

    try:
        inserted = (
            db.table("users")
            .insert({"owner_id": owner_id, "name": name, "level": level, "whatsapp_number": whatsapp_number})
            .execute()
        )
        return inserted.data[0]["id"]
    except Exception as exc:  # noqa: BLE001
        if not is_unique_violation(exc):
            raise
        # Another request created the same user a moment ago — use theirs.
        again = db.table("users").select("id").eq("owner_id", owner_id).eq("name", name).limit(1).execute()
        if again.data:
            return again.data[0]["id"]
        raise


def save_extracted_records(
    db: Client, owner_id: str, report_id: str, records: List[ExtractedRecord]
) -> Tuple[int, List[str]]:
    """
    Persists each extracted record as a bonus_results row, creating/reusing
    this admin's users as needed. Done in bulk (a few requests per
    ~200 rows rather than several per row) so a report with hundreds of
    users stays well inside the app's upload timeout.

    Returns (saved_count, warnings). A single bad row is recorded as a
    warning and skipped rather than failing the whole upload.
    """
    warnings: List[str] = []

    # A user can appear only once per report (database rule). Keep the first
    # occurrence and say so loudly rather than silently dropping the rest.
    seen: dict = {}
    unique: List[ExtractedRecord] = []
    for record in records:
        if record.user_name in seen:
            warnings.append(
                f"Duplicate user '{record.user_name}' (page {record.source_page}) skipped — "
                "that user already appears earlier in this report."
            )
            continue
        seen[record.user_name] = record
        unique.append(record)

    existing_rows = fetch_all(
        lambda a, b: db.table("users")
        .select("id, name, level, whatsapp_number")
        .eq("owner_id", owner_id)
        .order("id")
        .range(a, b)
        .execute()
    )
    users_by_name = {row["name"]: row for row in existing_rows}
    preexisting = set(users_by_name)

    # --- create users we haven't seen before (bulk) --------------------------
    to_create = [r for r in unique if r.user_name not in users_by_name]
    for chunk in chunked(to_create, INSERT_CHUNK):
        payload = [
            {"owner_id": owner_id, "name": r.user_name, "level": r.level, "whatsapp_number": r.whatsapp_number}
            for r in chunk
        ]
        try:
            created = db.table("users").insert(payload).execute()
            for row in created.data:
                users_by_name[row["name"]] = row
        except Exception as exc:  # noqa: BLE001
            logger.warning("Bulk user insert failed (%s); retrying row by row", safe_error(exc))
            for r in chunk:
                try:
                    user_id = get_or_create_user(db, owner_id, r.user_name, r.level, r.whatsapp_number)
                    users_by_name[r.user_name] = {"id": user_id, "name": r.user_name}
                except Exception as row_exc:  # noqa: BLE001
                    warnings.append(f"Could not save user '{r.user_name}' (page {r.source_page}).")

    # --- refresh details of users that already existed -------------------------
    for r in unique:
        if r.user_name not in preexisting:
            continue
        user = users_by_name[r.user_name]
        updates = {}
        if r.level and user.get("level") != r.level:
            updates["level"] = r.level
        if r.whatsapp_number and not user.get("whatsapp_number"):
            updates["whatsapp_number"] = r.whatsapp_number
        if updates:
            try:
                db.table("users").update(updates).eq("owner_id", owner_id).eq("id", user["id"]).execute()
            except Exception as exc:  # noqa: BLE001
                warnings.append(f"Could not update details for '{r.user_name}'.")

    # --- insert the report's rows (bulk) ----------------------------------------
    rows = []
    for r in unique:
        user = users_by_name.get(r.user_name)
        if not user:
            continue  # its user could not be saved; a warning was already recorded
        rows.append(
            {
                "owner_id": owner_id,
                "report_id": report_id,
                "user_id": user["id"],
                "casino_pts": r.casino_pts,
                "sport_pts": r.sport_pts,
                "third_party_pts": r.third_party_pts,
                "profit_loss": r.profit_loss,
                "ptype": r.ptype,
                "_name": r.user_name,
                "_page": r.source_page,
            }
        )

    saved = 0
    for chunk in chunked(rows, INSERT_CHUNK):
        payload = [{k: v for k, v in row.items() if not k.startswith("_")} for row in chunk]
        try:
            db.table("bonus_results").insert(payload).execute()
            saved += len(chunk)
        except Exception as exc:  # noqa: BLE001
            logger.warning("Bulk result insert failed (%s); retrying row by row", safe_error(exc))
            for row, single in zip(chunk, payload):
                try:
                    db.table("bonus_results").insert(single).execute()
                    saved += 1
                except Exception as row_exc:  # noqa: BLE001
                    warnings.append(
                        f"Could not save row for '{row['_name']}' (page {row['_page']})."
                    )

    return saved, warnings
