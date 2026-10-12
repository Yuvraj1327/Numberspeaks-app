"""
Casino-user management: profiles, the WhatsApp number the admin saves by
hand, carried-forward balances and calculation history.

These "users" are the people who appear in the weekly report and receive
bonuses. They do NOT log in — the admin operates the app. Every query is
scoped by `owner_id` (see app/services/reports_service.py).
"""

import re
from decimal import Decimal
from typing import Dict, List, Optional, Set

from fastapi import HTTPException, status
from supabase import Client

from app.schemas.users import HistoryEntry, UserProfile
from app.services.bonus_calculator import ZERO, to_decimal
from app.services.reports_service import fetch_all, is_valid_uuid, list_reports

_PHONE_ALLOWED = re.compile(r"^\+?[0-9\s\-()]+$")


def normalize_whatsapp_number(raw: Optional[str]) -> Optional[str]:
    """
    Cleans an admin-typed WhatsApp number: removes spaces, dashes and
    brackets, keeps a leading '+', and requires 7-15 digits (the E.164
    maximum). An empty value clears the number (returns None). Raises 422
    for anything that isn't a plausible phone number.
    """
    if raw is None:
        return None
    text = raw.strip()
    if text == "":
        return None
    if not _PHONE_ALLOWED.match(text):
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail="WhatsApp number may only contain digits, spaces, '-', brackets and a leading '+'.",
        )
    digits = re.sub(r"\D", "", text)
    if not 7 <= len(digits) <= 15:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail="WhatsApp number must have between 7 and 15 digits, including the country code.",
        )
    return ("+" if text.startswith("+") else "") + digits


def get_user(db: Client, owner_id: str, user_id: str) -> Optional[dict]:
    if not is_valid_uuid(user_id):
        return None
    res = db.table("users").select("*").eq("owner_id", owner_id).eq("id", user_id).limit(1).execute()
    return res.data[0] if res.data else None


def list_users(db: Client, owner_id: str, query: Optional[str] = None) -> List[dict]:
    def build(a: int, b: int):
        q = db.table("users").select("*").eq("owner_id", owner_id)
        if query and query.strip():
            q = q.ilike("name", f"%{query.strip()}%")
        return q.order("name").order("id").range(a, b).execute()

    return fetch_all(build)


def update_whatsapp_number(db: Client, owner_id: str, user_id: str, number: Optional[str]) -> dict:
    """Saves (or clears) the user's WhatsApp number permanently."""
    cleaned = normalize_whatsapp_number(number)
    user = get_user(db, owner_id, user_id)
    if user is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail=f"No user found with id {user_id}")
    db.table("users").update({"whatsapp_number": cleaned}).eq("owner_id", owner_id).eq("id", user_id).execute()
    user["whatsapp_number"] = cleaned
    return user


def previous_balances(
    db: Client,
    owner_id: str,
    before_uploaded_at: Optional[str] = None,
    needed_user_ids: Optional[Set[str]] = None,
) -> Dict[str, Decimal]:
    """
    Each user's carried-forward balance from their MOST RECENT earlier
    calculated period.

    "Earlier" = reports (of this admin) that are completed and were uploaded
    before `before_uploaded_at` (or all completed reports if None). A user
    absent from the immediately previous report keeps the balance from the
    last report they appeared in. Stops walking back as soon as every user
    in `needed_user_ids` is resolved.
    """
    reports = [r for r in list_reports(db, owner_id) if r.get("status") == "completed"]
    if before_uploaded_at is not None:
        reports = [r for r in reports if (r.get("uploaded_at") or "") < before_uploaded_at]
    reports.sort(key=lambda r: r.get("uploaded_at") or "", reverse=True)

    balances: Dict[str, Decimal] = {}
    for report in reports:
        if needed_user_ids is not None and needed_user_ids.issubset(balances):
            break
        rows = fetch_all(
            lambda a, b, rid=report["id"]: db.table("bonus_results")
            .select("user_id, carry_forward_balance")
            .eq("owner_id", owner_id)
            .eq("report_id", rid)
            .eq("calculation_status", "calculated")
            .order("id")
            .range(a, b)
            .execute()
        )
        for row in rows:
            uid = row["user_id"]
            if uid in balances:
                continue
            if needed_user_ids is not None and uid not in needed_user_ids:
                continue
            carry = row.get("carry_forward_balance")
            balances[uid] = to_decimal(carry) if carry is not None else ZERO
    return balances


def to_profile(user: dict, carry: Optional[Decimal] = None) -> UserProfile:
    return UserProfile(
        user_id=user["id"],
        name=user.get("name", ""),
        level=user.get("level"),
        whatsapp_number=user.get("whatsapp_number"),
        carry_forward_balance=None if carry is None else float(carry),
        created_at=user.get("created_at"),
    )


def get_history(db: Client, owner_id: str, user_id: str) -> List[HistoryEntry]:
    """Every calculation ever run for this user (newest first), including
    recalculations — the audit trail behind the current numbers."""
    rows = fetch_all(
        lambda a, b: db.table("calculation_history")
        .select("*")
        .eq("owner_id", owner_id)
        .eq("user_id", user_id)
        .order("calculated_at", desc=True)
        .order("id")
        .range(a, b)
        .execute()
    )
    names = {r["id"]: r.get("file_name") for r in list_reports(db, owner_id)}
    return [
        HistoryEntry(
            history_id=r["id"],
            run_id=r["run_id"],
            report_id=r["report_id"],
            report_file_name=names.get(r["report_id"]),
            calculated_at=r["calculated_at"],
            profit_loss=float(r["profit_loss"]),
            personal_rate=float(r["personal_rate"]),
            personal_adjustment=float(r["personal_adjustment"]),
            referral_adjustment=float(r["referral_adjustment"]),
            previous_balance=float(r["previous_balance"]),
            final_balance=float(r["final_balance"]),
            payable_bonus=float(r["payable_bonus"]),
            carry_forward_balance=float(r["carry_forward_balance"]),
        )
        for r in rows
    ]
