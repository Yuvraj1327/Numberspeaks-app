"""
CSV exports and JSON backup/restore for one admin's data.

Everything is scoped by `owner_id`. Restore NEVER trusts the file for
ownership: every row is stamped with the caller's id, only whitelisted
columns are written, and a row whose id already exists under another
account is refused (so a crafted file cannot overwrite someone else's data).
Restore is a merge (upsert by id): it adds missing rows and brings existing
ones back to the backed-up values; it never deletes anything.
"""

import csv
import io
import logging
from datetime import datetime, timezone
from typing import Dict, List, Tuple

from fastapi import HTTPException, status
from supabase import Client

from app.services import referral_service
from app.services.reports_service import chunked, fetch_all, is_valid_uuid, safe_error

logger = logging.getLogger("numberspeaks")

BACKUP_VERSION = 1

# Restore order matters (foreign keys): parents before children.
COLUMNS: Dict[str, Tuple[str, ...]] = {
    "users": ("id", "name", "level", "whatsapp_number", "is_active", "created_at"),
    "reports": (
        "id", "file_name", "file_path", "status", "uploaded_at", "period_start", "period_end",
        "user_count", "payable_user_count", "total_payable", "calculated_at",
    ),
    "bonus_results": (
        "id", "report_id", "user_id", "casino_pts", "sport_pts", "third_party_pts", "profit_loss", "ptype",
        "bonus_amount", "calculation_status", "created_at", "personal_rate_used", "personal_adjustment",
        "referral_adjustment", "previous_balance", "final_balance", "payable_bonus", "carry_forward_balance",
        "calculated_at", "whatsapp_send_status", "whatsapp_send_error", "whatsapp_sent_at",
    ),
    "referrers": ("id", "user_id", "display_name", "notes", "default_rate", "is_active", "created_at"),
    "referral_entries": (
        "id", "report_id", "referrer_user_id", "referred_user_id", "rate", "manual_amount", "note",
        "amount", "adjustment", "calculated_at", "created_at",
    ),
}
SETTINGS_COLUMNS = ("personal_rate", "referral_rate", "whatsapp_template")
MAX_RESTORE_ROWS = 200_000


def _all(db: Client, table: str, owner_id: str) -> List[dict]:
    return fetch_all(
        lambda a, b: db.table(table).select("*").eq("owner_id", owner_id).order("id").range(a, b).execute()
    )


def build_backup(db: Client, owner_id: str) -> dict:
    data = {t: [{c: r.get(c) for c in cols} for r in _all(db, t, owner_id)] for t, cols in COLUMNS.items()}
    settings = db.table("bonus_settings").select("*").eq("owner_id", owner_id).limit(1).execute().data
    return {
        "app": "numberspeaks",
        "version": BACKUP_VERSION,
        "exported_at": datetime.now(timezone.utc).isoformat(),
        "tables": data,
        "settings": {c: settings[0].get(c) for c in SETTINGS_COLUMNS} if settings else None,
    }


def restore_backup(db: Client, owner_id: str, backup: dict) -> Dict[str, int]:
    if backup.get("app") != "numberspeaks" or not isinstance(backup.get("tables"), dict):
        raise HTTPException(status_code=422, detail="This is not a Numberspeaks backup file.")
    if backup.get("version") != BACKUP_VERSION:
        raise HTTPException(status_code=422, detail=f"Unsupported backup version {backup.get('version')!r}.")
    tables = backup["tables"]
    if sum(len(v) for v in tables.values() if isinstance(v, list)) > MAX_RESTORE_ROWS:
        raise HTTPException(status_code=413, detail="Backup file is too large.")

    # --- validate everything first: nothing is written if the file is bad ----
    prepared: Dict[str, List[dict]] = {}
    for table, cols in COLUMNS.items():
        rows = tables.get(table, [])
        if not isinstance(rows, list):
            raise HTTPException(status_code=422, detail=f"'{table}' must be a list.")
        clean = []
        for row in rows:
            if not isinstance(row, dict) or not is_valid_uuid(row.get("id")):
                raise HTTPException(status_code=422, detail=f"A '{table}' row has a missing or invalid id.")
            item = {c: row[c] for c in cols if c in row}
            item["owner_id"] = owner_id
            clean.append(item)
        prepared[table] = clean

    for table, rows in prepared.items():
        ids = [r["id"] for r in rows]
        for chunk in chunked(ids, 200):
            found = db.table(table).select("id, owner_id").in_("id", chunk).execute().data or []
            if any(f.get("owner_id") not in (owner_id, None) for f in found):
                raise HTTPException(
                    status_code=status.HTTP_409_CONFLICT,
                    detail=f"The backup contains {table} that belong to another account. Nothing was restored.",
                )

    restored: Dict[str, int] = {}
    for table, rows in prepared.items():
        count = 0
        for chunk in chunked(rows, 200):
            try:
                db.table(table).upsert(chunk, on_conflict="id").execute()
                count += len(chunk)
            except Exception as exc:  # noqa: BLE001
                logger.warning("Bulk restore of %s failed (%s); retrying row by row", table, safe_error(exc))
                for row in chunk:
                    try:
                        db.table(table).upsert(row, on_conflict="id").execute()
                        count += 1
                    except Exception as row_exc:  # noqa: BLE001
                        logger.warning("Skipped one %s row: %s", table, safe_error(row_exc))
        restored[table] = count

    settings = backup.get("settings")
    if isinstance(settings, dict):
        item = {c: settings[c] for c in SETTINGS_COLUMNS if c in settings}
        item["owner_id"] = owner_id
        db.table("bonus_settings").upsert(item, on_conflict="owner_id").execute()
        restored["settings"] = 1
    return restored


# --- CSV ---------------------------------------------------------------------


def _text(value) -> str:
    """Names/notes are admin- or PDF-supplied: neutralise spreadsheet formulas."""
    text = "" if value is None else str(value)
    return "'" + text if text[:1] in ("=", "+", "-", "@", "\t", "\r") else text


def _csv(header: List[str], rows: List[list]) -> str:
    out = io.StringIO()
    writer = csv.writer(out)
    writer.writerow(header)
    writer.writerows(rows)
    return out.getvalue()


def users_csv(db: Client, owner_id: str) -> str:
    from app.services.users_service import list_users, previous_balances

    users = list_users(db, owner_id)
    balances = previous_balances(db, owner_id)
    return _csv(
        ["user_id", "name", "level", "whatsapp_number", "carried_balance"],
        [
            [u["id"], _text(u.get("name")), _text(u.get("level")), _text(u.get("whatsapp_number")), balances.get(u["id"], "")]
            for u in users
        ],
    )


def referrals_csv(db: Client, owner_id: str) -> str:
    rows = []
    for e in referral_service.ledger(db, owner_id):
        rows.append(
            [
                e.period_start or "", e.period_end or "", e.referrer_user_id, _text(e.referrer_name),
                e.referred_user_id, _text(e.referred_name), e.amount if e.amount is not None else "",
                e.amount_source, e.rate, e.adjustment if e.adjustment is not None else "", _text(e.note),
            ]
        )
    return _csv(
        ["period_start", "period_end", "referrer_id", "referrer_name", "referred_id", "referred_name",
         "profit_loss", "amount_source", "rate", "adjustment", "note"],
        rows,
    )


def report_csv(db: Client, owner_id: str, report_id: str) -> str:
    from app.services.reports_service import get_bonus_results_for_report, to_bonus_result

    rows = []
    for raw in get_bonus_results_for_report(db, owner_id, report_id):
        r = to_bonus_result(raw)
        rows.append(
            [
                r.user_id, _text(r.user_name), _text(r.level), _text(r.whatsapp_number), r.profit_loss,
                r.personal_adjustment, r.referral_adjustment, r.previous_balance, r.final_balance,
                r.payable_bonus, r.carry_forward_balance,
            ]
        )
    return _csv(
        ["user_id", "name", "level", "whatsapp_number", "profit_loss", "personal_adjustment",
         "referral_adjustment", "previous_balance", "final_balance", "payable_bonus", "carry_forward_balance"],
        rows,
    )
