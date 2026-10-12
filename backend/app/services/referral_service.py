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

from typing import Dict, List, Optional

from fastapi import HTTPException, status
from supabase import Client

from app.schemas.referral import (
    ReferralCreate,
    ReferralEntry,
    ReferralUpdate,
    Referrer,
    ReferrerIn,
    ReferrerUpdate,
)
from app.services.reports_service import (
    fetch_all,
    get_report,
    get_bonus_result_for_user,
    get_bonus_results_for_report,
    is_unique_violation,
    is_valid_uuid,
    list_reports,
    report_sort_key,
    update_report_status,
)
from app.services.settings_service import get_bonus_settings
from app.services.users_service import get_user


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


def to_entry(row: dict, names: Dict[str, str], report: Optional[dict] = None) -> ReferralEntry:
    manual = row.get("manual_amount")
    amount = row.get("amount") if manual is None else manual
    return ReferralEntry(
        amount_source="report" if manual is None else "manual",
        note=row.get("note"),
        period_start=(report or {}).get("period_start"),
        period_end=(report or {}).get("period_end"),
        entry_id=row["id"],
        report_id=row["report_id"],
        referrer_user_id=row["referrer_user_id"],
        referrer_name=names.get(row["referrer_user_id"]),
        referred_user_id=row["referred_user_id"],
        referred_name=names.get(row["referred_user_id"]),
        rate=float(row["rate"]),
        amount=None if amount is None else float(amount),
        adjustment=None if row.get("adjustment") is None else float(row["adjustment"]),
        calculated_at=row.get("calculated_at"),
        created_at=row.get("created_at"),
    )


def list_entries(db: Client, owner_id: str, report_id: str) -> List[ReferralEntry]:
    names = _names_in_report(db, owner_id, report_id)
    report = get_report(db, owner_id, report_id)
    return [to_entry(row, names, report) for row in fetch_entry_rows(db, owner_id, report_id)]


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

    manual = payload.amount
    for label, uid in (("Referrer", referrer_id), ("Referred user", referred_id)):
        if get_bonus_result_for_user(db, owner_id, report_id, uid) is not None:
            continue
        if label == "Referred user" and manual is not None and get_user(db, owner_id, uid) is not None:
            continue  # a manual amount stands in for the missing report row
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail=f"{label} is not in this report. Both users must appear in the report's period "
            "(or enter the referred user's amount manually).",
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

    rate = payload.rate
    if rate is None:
        rate = _default_rate(db, owner_id, referrer_id)

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
                    "manual_amount": manual,
                    "note": (payload.note or "").strip() or None,
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

    return to_entry(inserted.data[0], names, report)


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


def _default_rate(db: Client, owner_id: str, referrer_user_id: str) -> float:
    """The referrer's own default rate if the admin set one, else the global one (10%)."""
    res = (
        db.table("referrers")
        .select("default_rate")
        .eq("owner_id", owner_id)
        .eq("user_id", referrer_user_id)
        .limit(1)
        .execute()
    )
    if res.data and res.data[0].get("default_rate") is not None:
        return float(res.data[0]["default_rate"])
    return get_bonus_settings(db, owner_id).referral_rate


def update_entry(db: Client, owner_id: str, report: dict, entry_id: str, payload: ReferralUpdate) -> ReferralEntry:
    report_id = report["id"]
    if not is_valid_uuid(entry_id):
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Referral entry not found.")
    found = [e for e in fetch_entry_rows(db, owner_id, report_id) if e["id"] == entry_id]
    if not found:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Referral entry not found.")
    changes: dict = {}
    if payload.rate is not None:
        changes["rate"] = payload.rate
    if payload.clear_amount:
        changes["manual_amount"] = None
    elif payload.amount is not None:
        changes["manual_amount"] = payload.amount
    if payload.note is not None:
        changes["note"] = payload.note.strip() or None
    if changes:
        # The stored adjustment is stale until the report is recalculated.
        if set(changes) & {"rate", "manual_amount"}:
            changes.update({"adjustment": None, "calculated_at": None})
        db.table("referral_entries").update(changes).eq("owner_id", owner_id).eq("id", entry_id).execute()
        if set(changes) & {"rate", "manual_amount"} and report.get("status") == "completed":
            update_report_status(db, owner_id, report_id, "processing")
    row = [e for e in fetch_entry_rows(db, owner_id, report_id) if e["id"] == entry_id][0]
    return to_entry(row, _names_in_report(db, owner_id, report_id), report)


def snapshot_referrals(db: Client, owner_id: str, report_id: str) -> List[dict]:
    """What the admin entered (not the computed numbers), so a deliberate
    replace of a week's PDF doesn't lose their referral entries."""
    keep = ("referrer_user_id", "referred_user_id", "rate", "manual_amount", "note")
    return [{k: e.get(k) for k in keep} for e in fetch_entry_rows(db, owner_id, report_id)]


def restore_referrals(db: Client, owner_id: str, report_id: str, entries: List[dict]) -> None:
    present = {r["user_id"] for r in get_bonus_results_for_report(db, owner_id, report_id)}
    for e in entries:
        if e["referrer_user_id"] not in present:
            continue
        if e["referred_user_id"] not in present and e.get("manual_amount") is None:
            continue
        try:
            db.table("referral_entries").insert({"owner_id": owner_id, "report_id": report_id, **e}).execute()
        except Exception:  # noqa: BLE001 - a clash just means it is already there
            continue


def all_user_names(db: Client, owner_id: str) -> Dict[str, str]:
    return {
        u["id"]: u.get("name", "")
        for u in fetch_all(
            lambda a, b: db.table("users").select("id, name").eq("owner_id", owner_id).order("id").range(a, b).execute()
        )
    }


def ledger(db: Client, owner_id: str) -> List[ReferralEntry]:
    """Every referral entry across ALL weeks, newest period first."""
    reports = {r["id"]: r for r in list_reports(db, owner_id)}
    names = all_user_names(db, owner_id)
    rows = fetch_all(
        lambda a, b: db.table("referral_entries")
        .select("*")
        .eq("owner_id", owner_id)
        .order("created_at")
        .order("id")
        .range(a, b)
        .execute()
    )
    rows.sort(key=lambda r: report_sort_key(reports.get(r["report_id"], {})), reverse=True)
    return [to_entry(r, names, reports.get(r["report_id"])) for r in rows if r["report_id"] in reports]


# --- referrers (persistent referrer details) ------------------------------------


def _referrer_totals(db: Client, owner_id: str) -> Dict[str, dict]:
    totals: Dict[str, dict] = {}
    for e in ledger(db, owner_id):
        t = totals.setdefault(e.referrer_user_id, {"referred": set(), "total": 0.0})
        t["referred"].add(e.referred_user_id)
        t["total"] += e.adjustment or 0.0
    return totals


def _to_referrer(row: dict, names: Dict[str, str], totals: Dict[str, dict]) -> Referrer:
    t = totals.get(row["user_id"], {"referred": set(), "total": 0.0})
    return Referrer(
        referrer_id=row["id"],
        user_id=row["user_id"],
        user_name=names.get(row["user_id"]),
        display_name=row.get("display_name"),
        notes=row.get("notes"),
        default_rate=None if row.get("default_rate") is None else float(row["default_rate"]),
        is_active=bool(row.get("is_active", True)),
        referred_count=len(t["referred"]),
        total_adjustment=round(t["total"], 2),
    )


def list_referrers(db: Client, owner_id: str) -> List[Referrer]:
    names = all_user_names(db, owner_id)
    totals = _referrer_totals(db, owner_id)
    rows = fetch_all(
        lambda a, b: db.table("referrers").select("*").eq("owner_id", owner_id).order("created_at").order("id").range(a, b).execute()
    )
    return [_to_referrer(r, names, totals) for r in rows]


def create_referrer(db: Client, owner_id: str, payload: ReferrerIn) -> Referrer:
    if get_user(db, owner_id, payload.user_id) is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="No such user.")
    try:
        res = db.table("referrers").insert(
            {
                "owner_id": owner_id,
                "user_id": payload.user_id,
                "display_name": (payload.display_name or "").strip() or None,
                "notes": (payload.notes or "").strip() or None,
                "default_rate": payload.default_rate,
                "is_active": payload.is_active,
            }
        ).execute()
    except Exception as exc:  # noqa: BLE001
        if is_unique_violation(exc):
            raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail="This user is already a referrer.") from exc
        raise
    return _to_referrer(res.data[0], all_user_names(db, owner_id), _referrer_totals(db, owner_id))


def _referrer_row(db: Client, owner_id: str, referrer_id: str) -> dict:
    if is_valid_uuid(referrer_id):
        res = db.table("referrers").select("*").eq("owner_id", owner_id).eq("id", referrer_id).limit(1).execute()
        if res.data:
            return res.data[0]
    raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Referrer not found.")


def update_referrer(db: Client, owner_id: str, referrer_id: str, payload: ReferrerUpdate) -> Referrer:
    _referrer_row(db, owner_id, referrer_id)
    changes: dict = {}
    if payload.display_name is not None:
        changes["display_name"] = payload.display_name.strip() or None
    if payload.notes is not None:
        changes["notes"] = payload.notes.strip() or None
    if payload.clear_default_rate:
        changes["default_rate"] = None
    elif payload.default_rate is not None:
        changes["default_rate"] = payload.default_rate
    if payload.is_active is not None:
        changes["is_active"] = payload.is_active
    if changes:
        db.table("referrers").update(changes).eq("owner_id", owner_id).eq("id", referrer_id).execute()
    row = _referrer_row(db, owner_id, referrer_id)
    return _to_referrer(row, all_user_names(db, owner_id), _referrer_totals(db, owner_id))


def delete_referrer(db: Client, owner_id: str, referrer_id: str) -> None:
    """Removes only the saved referrer details; the ledger entries stay."""
    _referrer_row(db, owner_id, referrer_id)
    db.table("referrers").delete().eq("owner_id", owner_id).eq("id", referrer_id).execute()


def annotate_results(db: Client, owner_id: str, report_id: str, results: list) -> list:
    """Adds 'who referred this user' / 'how many users they referred' to
    BonusResult objects so the app can show it beside the name."""
    entries = fetch_entry_rows(db, owner_id, report_id)
    if not entries:
        return results
    names = all_user_names(db, owner_id)
    by_referred = {e["referred_user_id"]: e for e in entries}
    referred_counts: Dict[str, int] = {}
    for e in entries:
        referred_counts[e["referrer_user_id"]] = referred_counts.get(e["referrer_user_id"], 0) + 1
    for r in results:
        link = by_referred.get(r.user_id)
        if link:
            r.referrer_user_id = link["referrer_user_id"]
            r.referrer_name = names.get(link["referrer_user_id"])
        r.referred_count = referred_counts.get(r.user_id, 0)
    return results
