"""
Supabase persistence for uploaded reports and their extracted rows.

Keeps every Supabase read/write for this feature in one place, on top of
the shared client from app/db/supabase_client.py. The route handler in
app/api/v1/endpoints/reports.py orchestrates these calls; it does not talk
to Supabase directly.
"""

import logging
from typing import List, Optional, Tuple

from supabase import Client

from app.schemas.bonus import BonusResult
from app.schemas.report import ExtractedRecord

logger = logging.getLogger("numberspeaks")

REPORTS_BUCKET = "reports"


def get_report(db: Client, report_id: str) -> Optional[dict]:
    res = db.table("reports").select("*").eq("id", report_id).limit(1).execute()
    return res.data[0] if res.data else None


BONUS_RESULT_SELECT = (
    "id, report_id, user_id, casino_pts, sport_pts, third_party_pts, "
    "profit_loss, ptype, bonus_amount, created_at, "
    "users(id, name, level, whatsapp_number)"
)


def get_bonus_results_for_report(db: Client, report_id: str) -> List[dict]:
    """
    Returns this report's extracted rows, each joined with its user's
    name and level — i.e. exactly the data Step 3 saved, reassembled into
    the same shape the PDF had.
    """
    res = (
        db.table("bonus_results")
        .select(BONUS_RESULT_SELECT)
        .eq("report_id", report_id)
        .execute()
    )
    return res.data


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


def update_bonus_amount(db: Client, bonus_result_id: str, bonus_amount: float) -> None:
    db.table("bonus_results").update({"bonus_amount": bonus_amount}).eq("id", bonus_result_id).execute()


def bonus_result_row_to_raw(row: dict) -> dict:
    """
    Reshapes a joined bonus_results+users row back into the report's 8
    columns, for re-running through the same validator Step 4 uses. Keeps
    the row's own id under a private key so callers can trace back to it
    without that id leaking into any user-facing 'raw' output.
    """
    user = row.get("users") or {}
    return {
        "no": None,  # not persisted — it's the PDF's own row number, not a DB concept
        "user_name": user.get("name"),
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
        level=user.get("level"),
        casino_pts=row.get("casino_pts", 0.0),
        sport_pts=row.get("sport_pts", 0.0),
        third_party_pts=row.get("third_party_pts", 0.0),
        profit_loss=row.get("profit_loss", 0.0),
        ptype=row.get("ptype"),
        bonus_amount=row.get("bonus_amount"),
        created_at=row.get("created_at"),
    )


def create_report(db: Client, file_name: str) -> dict:
    """Inserts the initial reports row. file_path is filled in once the
    file has actually been stored (see update_report_file_path)."""
    res = (
        db.table("reports")
        .insert({"file_name": file_name, "file_path": "", "status": "uploaded"})
        .execute()
    )
    return res.data[0]


def update_report_file_path(db: Client, report_id: str, file_path: str) -> None:
    db.table("reports").update({"file_path": file_path}).eq("id", report_id).execute()


def update_report_status(db: Client, report_id: str, status: str) -> None:
    db.table("reports").update({"status": status}).eq("id", report_id).execute()


def upload_pdf_to_storage(db: Client, report_id: str, file_name: str, file_bytes: bytes) -> str:
    """
    Uploads the raw PDF to Supabase Storage and returns its storage path.
    Requires a bucket named 'reports' to already exist (see
    supabase/storage_setup.sql).
    """
    storage_path = f"{report_id}/{file_name}"
    db.storage.from_(REPORTS_BUCKET).upload(
        storage_path,
        file_bytes,
        {"content-type": "application/pdf"},
    )
    return storage_path


def get_or_create_user(db: Client, name: str, level: Optional[str]) -> str:
    """
    Finds an existing user by exact name match, or creates one.

    Matching by name (rather than generating a new user per report) keeps
    the same person's bonus history linked across multiple report uploads.
    If a match is found and the report shows a different level, the
    user's level is updated to the latest value.
    """
    existing = db.table("users").select("id, level").eq("name", name).limit(1).execute()

    if existing.data:
        user_id = existing.data[0]["id"]
        if level and existing.data[0].get("level") != level:
            db.table("users").update({"level": level}).eq("id", user_id).execute()
        return user_id

    inserted = db.table("users").insert({"name": name, "level": level}).execute()
    return inserted.data[0]["id"]


def save_extracted_records(
    db: Client, report_id: str, records: List[ExtractedRecord]
) -> Tuple[int, List[str]]:
    """
    Persists each extracted record as a bonus_results row, creating/reusing
    users as needed. bonus_amount is left null — no formula exists yet.

    Returns (saved_count, warnings). A single row's DB error is recorded
    as a warning and skipped rather than failing the whole upload, since
    the rest of the report may still be good data.
    """
    saved = 0
    warnings: List[str] = []

    for record in records:
        try:
            user_id = get_or_create_user(db, record.user_name, record.level)
            db.table("bonus_results").insert({
                "report_id": report_id,
                "user_id": user_id,
                "casino_pts": record.casino_pts,
                "sport_pts": record.sport_pts,
                "third_party_pts": record.third_party_pts,
                "profit_loss": record.profit_loss,
                "ptype": record.ptype,
            }).execute()
            saved += 1
        except Exception as exc:  # noqa: BLE001
            logger.warning(
                "Failed to save bonus_results row for %r on report %s: %s",
                record.user_name, report_id, exc,
            )
            warnings.append(
                f"Could not save row for '{record.user_name}' "
                f"(page {record.source_page}): {exc}"
            )

    return saved, warnings
