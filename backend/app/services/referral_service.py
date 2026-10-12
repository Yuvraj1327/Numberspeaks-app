"""
Referral entries — kept completely separate from personal bonuses.

An entry says: "in this period (report), user B was referred by user A".
When the report is calculated, B's profit/loss for that period feeds A's
referral adjustment at the entry's rate (10% by default):

    B lost 10,000 -> A gets +1,000      B won 10,000 -> A gets -1,000

Double counting is prevented twice: in code (friendly 409 messages) and by
a database unique constraint on (owner, report, referred user) — one
referred user's result can only feed ONE referrer in a period.
"""

from typing import Dict, List

from fastapi import HTTPException, status
from supabase import Client

from app.schemas.referral import ReferralCreate, ReferralEntry
from app.services.reports_service import (
    fetch_all,
    get_bonus_result_for_user,
    get_bonus_results_for_report,
    is_unique_violation,
    is_valid_uuid,
    update_report_status,
)
from app.services.settings_service import get_bonus_settings


def fetch_entry_rows(db: Client, owner_id: str, report_id: str) -> List[dict]:
    return fetch_all(
        lambda a, b: db.table("referral_entries")
        .select("*")
        .eq("owner_id", owner_id)
        .eq("report_id", report_id)
        .order("created_at")
        .order("id")
        .range(a, b)
        .execute()
    )


def _names_in_report(db: Client, owner_id: str, report_id: str) -> Dict[str, str]:
    names: Dict[str, str] = {}
    for row in get_bonus_results_for_report(db, owner_id, report_id):
        user = row.get("users") or {}
        names[row["user_id"]] = user.get("name", "")
    return names


def to_entry(row: dict, names: Dict[str, str]) -> ReferralEntry:
    return ReferralEntry(
        entry_id=row["id"],
        report_id=row["report_id"],
        referrer_user_id=row["referrer_user_id"],
        referrer_name=names.get(row["referrer_user_id"]),
        referred_user_id=row["referred_user_id"],
        referred_name=names.get(row["referred_user_id"]),
        rate=float(row["rate"]),
        amount=None if row.get("amount") is None else float(row["amount"]),
        adjustment=None if row.get("adjustment") is None else float(row["adjustment"]),
        calculated_at=row.get("calculated_at"),
        created_at=row.get("created_at"),
    )


def list_entries(db: Client, owner_id: str, report_id: str) -> List[ReferralEntry]:
    names = _names_in_report(db, owner_id, report_id)
    return [to_entry(row, names) for row in fetch_entry_rows(db, owner_id, report_id)]


def create_entry(db: Client, owner_id: str, report: dict, payload: ReferralCreate) -> ReferralEntry:
    report_id = report["id"]
    referrer_id = payload.referrer_user_id.strip()
    referred_id = payload.referred_user_id.strip()

    if not (is_valid_uuid(referrer_id) and is_valid_uuid(referred_id)):
        raise HTTPException(status_code=status.HTTP_422_UNPROCESSABLE_ENTITY, detail="Invalid user id.")
    if referrer_id == referred_id:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail="A user cannot be their own referrer.",
        )

    for label, uid in (("Referrer", referrer_id), ("Referred user", referred_id)):
        if get_bonus_result_for_user(db, owner_id, report_id, uid) is None:
            raise HTTPException(
                status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
                detail=f"{label} is not in this report. Both users must appear in the report's period.",
            )

    existing = fetch_entry_rows(db, owner_id, report_id)
    names = _names_in_report(db, owner_id, report_id)
    for entry in existing:
        if entry["referred_user_id"] != referred_id:
            continue
        if entry["referrer_user_id"] == referrer_id:
            raise HTTPException(
                status_code=status.HTTP_409_CONFLICT,
                detail="This referral is already recorded for this period.",
            )
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail=(
                f"'{names.get(referred_id, 'This user')}' is already linked to referrer "
                f"'{names.get(entry['referrer_user_id'], 'another user')}' in this period. "
                "Counting them for a second referrer would double count their result."
            ),
        )

    rate = payload.rate if payload.rate is not None else get_bonus_settings(db, owner_id).referral_rate

    try:
        inserted = (
            db.table("referral_entries")
            .insert(
                {
                    "owner_id": owner_id,
                    "report_id": report_id,
                    "referrer_user_id": referrer_id,
                    "referred_user_id": referred_id,
                    "rate": rate,
                }
            )
            .execute()
        )
    except Exception as exc:  # noqa: BLE001
        if is_unique_violation(exc):
            raise HTTPException(
                status_code=status.HTTP_409_CONFLICT,
                detail="This referred user is already linked to a referrer in this period.",
            ) from exc
        raise

    if report.get("status") == "completed":
        # The calculated numbers no longer include this entry — reopen the
        # report so it has to be recalculated before it counts as final.
        update_report_status(db, owner_id, report_id, "processing")

    return to_entry(inserted.data[0], names)


def delete_entry(db: Client, owner_id: str, report: dict, entry_id: str) -> None:
    report_id = report["id"]
    if not is_valid_uuid(entry_id):
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Referral entry not found.")
    found = (
        db.table("referral_entries")
        .select("id")
        .eq("owner_id", owner_id)
        .eq("report_id", report_id)
        .eq("id", entry_id)
        .limit(1)
        .execute()
    )
    if not found.data:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Referral entry not found.")

    db.table("referral_entries").delete().eq("owner_id", owner_id).eq("report_id", report_id).eq(
        "id", entry_id
    ).execute()

    if report.get("status") == "completed":
        update_report_status(db, owner_id, report_id, "processing")
