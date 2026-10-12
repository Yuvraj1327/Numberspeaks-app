"""
Admin corrections to extracted rows, applied before the bonus is confirmed.

PDF extraction can misread a value, so the admin reviews the extracted table
and fixes what's wrong. A correction changes stored data only — it never
computes anything. After a correction that affects the calculation the row is marked
'pending' (and a completed report is reopened) so the bonus is calculated
again from the corrected figures.
"""

import math
from typing import Optional

from fastapi import HTTPException, status
from supabase import Client

from app.schemas.bonus import RowCorrection
from app.services.reports_service import get_bonus_result_by_id, get_or_create_user, update_report_status
from app.services.users_service import normalize_whatsapp_number

NUMERIC_FIELDS = ("casino_pts", "sport_pts", "third_party_pts", "profit_loss")


def _clean_text(value: Optional[str]) -> Optional[str]:
    if value is None:
        return None
    text = value.strip()
    return text or None


def apply_row_correction(
    db: Client,
    owner_id: str,
    report: dict,
    bonus_result_id: str,
    correction: RowCorrection,
) -> dict:
    """Applies the corrections and returns the refreshed joined row."""
    report_id = report["id"]
    row = get_bonus_result_by_id(db, owner_id, report_id, bonus_result_id)
    if row is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail=f"No row found with id {bonus_result_id}")

    changes = correction.model_dump(exclude_unset=True)
    if not changes:
        return row

    row_updates: dict = {}
    user_updates: dict = {}
    current_user_id: str = row["user_id"]

    for field in NUMERIC_FIELDS:
        if field in changes:
            value = changes[field]
            if value is None or not math.isfinite(value):
                raise HTTPException(
                    status_code=status.HTTP_422_UNPROCESSABLE_ENTITY, detail=f"{field} must be a number."
                )
            row_updates[field] = value

    if "ptype" in changes:
        row_updates["ptype"] = _clean_text(changes["ptype"])
    if "level" in changes:
        user_updates["level"] = _clean_text(changes["level"])
    if "whatsapp_number" in changes:
        user_updates["whatsapp_number"] = normalize_whatsapp_number(changes["whatsapp_number"])

    if "user_name" in changes:
        new_name = _clean_text(changes["user_name"])
        if new_name is None:
            raise HTTPException(
                status_code=status.HTTP_422_UNPROCESSABLE_ENTITY, detail="User ID / Name cannot be empty."
            )
        current_name = (row.get("users") or {}).get("name")
        if new_name != current_name:
            new_user_id = get_or_create_user(db, owner_id, new_name)
            clash = (
                db.table("bonus_results")
                .select("id")
                .eq("owner_id", owner_id)
                .eq("report_id", report_id)
                .eq("user_id", new_user_id)
                .limit(1)
                .execute()
            )
            if clash.data and clash.data[0]["id"] != bonus_result_id:
                raise HTTPException(
                    status_code=status.HTTP_409_CONFLICT,
                    detail=f"'{new_name}' already appears in this report. A user can only appear once per report.",
                )
            row_updates["user_id"] = new_user_id
            current_user_id = new_user_id

    if user_updates:
        db.table("users").update(user_updates).eq("owner_id", owner_id).eq("id", current_user_id).execute()

    # Only a change that feeds the calculation (a figure, or which user the
    # row belongs to) makes an earlier calculation stale. Level, Ptype and
    # the WhatsApp number do not affect any bonus, so they leave it alone.
    affects_calculation = any(f in row_updates for f in NUMERIC_FIELDS) or "user_id" in row_updates
    if affects_calculation and row.get("calculation_status") == "calculated":
        row_updates["calculation_status"] = "pending"
    if row_updates:
        db.table("bonus_results").update(row_updates).eq("owner_id", owner_id).eq("id", bonus_result_id).execute()

    if affects_calculation and report.get("status") == "completed":
        update_report_status(db, owner_id, report_id, "processing")

    return get_bonus_result_by_id(db, owner_id, report_id, bonus_result_id) or row
