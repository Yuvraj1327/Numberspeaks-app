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
    """All of this admin's reports, newest upload first."""
    return fetch_all(
        lambda a, b: db.table("reports")
        .select("*")
        .eq("owner_id", owner_id)
        .order("uploaded_at", desc=True)
        .order("id")
        .range(a, b)
        .execute()
    )


def to_report_summary(row: dict) -> ReportSummary:
    return ReportSummary(
        report_id=row["id"],
        file_name=row.get("file_name", ""),
        status=row.get("status", ""),
        uploaded_at=row.get("uploaded_at"),
        calculated_at=row.get("calculated_at"),
        user_count=row.get("user_count"),
        payable_user_count=row.get("payable_user_count"),
        total_payable=_f(row.get("total_payable")),
    )


def create_report(db: Client, owner_id: str, file_name: str) -> dict:
    """Inserts the initial reports row. file_path is filled in once the
    file has actually been stored (see update_report_file_path)."""
    res = (
        db.table("reports")
        .insert({"owner_id": owner_id, "file_name": file_name, "file_path": "", "status": "uploaded"})
        .execute()
    )
    return res.data[0]


def update_report_file_path(db: Client, owner_id: str, report_id: str, file_path: str) -> None:
    db.table("reports").update({"file_path": file_path}).eq("owner_id", owner_id).eq("id", report_id).execute()


def update_report_status(db: Client, owner_id: str, report_id: str, status: str) -> None:
    db.table("reports").update({"status": status}).eq("owner_id", owner_id).eq("id", report_id).execute()


def update_report_summary(db: Client, owner_id: str, report_id: str, fields: dict) -> None:
    db.table("reports").update(fields).eq("owner_id", owner_id).eq("id", report_id).execute()


def later_report_is_completed(db: Client, owner_id: str, report: dict) -> bool:
    """True if a report uploaded AFTER this one has already been calculated.

    Carry-forward balances flow from one period to the next, so recalculating
    or reopening an older report once a newer one is calculated would leave
    the newer report's "previous balance" stale. Callers block that case.
    """
    uploaded_at = report.get("uploaded_at")
    if not uploaded_at:
        return False
    res = (
        db.table("reports")
        .select("id")
        .eq("owner_id", owner_id)
        .eq("status", "completed")
        .gt("uploaded_at", uploaded_at)
        .limit(1)
        .execute()
    )
    return bool(res.data)


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
    "calculated_at, whatsapp_initiated_at, whatsapp_initiated_count, "
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
    initiated_at = row.get("whatsapp_initiated_at")
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
        whatsapp_status="initiated" if initiated_at else "not_sent",
        whatsapp_initiated_at=initiated_at,
        whatsapp_initiated_count=row.get("whatsapp_initiated_count") or 0,
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
