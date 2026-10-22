"""
Casino-user management: profiles, the WhatsApp number the admin saves by
hand, carried-forward balances and calculation history.

These "users" are the people who appear in the weekly report and receive
bonuses. They do NOT log in — the admin operates the app. Every query is
scoped by `owner_id` (see app/services/reports_service.py).
"""

import re
from datetime import date
from decimal import Decimal
from typing import Dict, List, Optional, Set, Tuple

from fastapi import HTTPException, status
from supabase import Client

from app.schemas.users import HistoryEntry, UserProfile, WeekEntry
from app.services.bonus_calculator import ZERO, to_decimal
from app.services.reports_service import fetch_all, is_valid_uuid, list_reports, report_sort_key

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


def to_international(number: str, default_country_code: str = "") -> str:
    """The digits WhatsApp needs: country code first, no '+'.

    A number saved with a leading '+' (or already longer than a local number) is used
    as typed. A bare 10-digit local number gets `default_country_code`, and a local
    number with a trunk '0' (11 digits starting with 0) loses the 0 first. Saved
    numbers are never rewritten: this only decides what is sent.
    """
    text = (number or "").strip()
    digits = re.sub(r"\D", "", text)
    cc = re.sub(r"\D", "", default_country_code or "")
    if not cc or text.startswith("+"):
        return digits
    if len(digits) == 11 and digits.startswith("0"):
        digits = digits[1:]
    return cc + digits if len(digits) == 10 else digits


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


def update_user(db: Client, owner_id: str, user_id: str, changes: dict) -> dict:
    """Edits a user's name, level and/or WhatsApp number (only the keys given)."""
    user = get_user(db, owner_id, user_id)
    if user is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail=f"No user found with id {user_id}")
    updates: dict = {}
    if "whatsapp_number" in changes:
        updates["whatsapp_number"] = normalize_whatsapp_number(changes["whatsapp_number"])
    if "level" in changes:
        updates["level"] = (changes["level"] or "").strip() or None
    if "name" in changes:
        name = (changes["name"] or "").strip()
        if not name:
            raise HTTPException(status_code=status.HTTP_422_UNPROCESSABLE_ENTITY, detail="Name cannot be empty.")
        if name != user.get("name"):
            clash = db.table("users").select("id").eq("owner_id", owner_id).eq("name", name).limit(1).execute()
            if clash.data:
                raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail=f"A user named '{name}' already exists.")
            updates["name"] = name
    if updates:
        db.table("users").update(updates).eq("owner_id", owner_id).eq("id", user_id).execute()
        user.update(updates)
    return user


def previous_state(
    db: Client,
    owner_id: str,
    before_report: Optional[dict] = None,
    needed_user_ids: Optional[Set[str]] = None,
) -> Dict[str, Tuple[Decimal, Decimal]]:
    """
    Each user's (carried-forward balance, cumulative report total) from their
    MOST RECENT earlier calculated period.

    "Earlier" = reports (of this admin) that are completed and were uploaded
    chronologically before `before_report` (by period; all completed reports if None). A user
    absent from the immediately previous report keeps the values from the
    last report they appeared in. Stops walking back as soon as every user
    in `needed_user_ids` is resolved. A user with no earlier report is simply
    absent from the result.
    """
    reports = [r for r in list_reports(db, owner_id) if r.get("status") == "completed"]
    if before_report is not None:
        limit = report_sort_key(before_report)
        reports = [r for r in reports if r["id"] != before_report["id"] and report_sort_key(r) < limit]
    reports.sort(key=report_sort_key, reverse=True)

    state: Dict[str, Tuple[Decimal, Decimal]] = {}
    for report in reports:
        if needed_user_ids is not None and needed_user_ids.issubset(state):
            break
        rows = fetch_all(
            lambda a, b, rid=report["id"]: db.table("bonus_results")
            .select("user_id, carry_forward_balance, profit_loss")
            .eq("owner_id", owner_id)
            .eq("report_id", rid)
            .eq("calculation_status", "calculated")
            .order("id")
            .range(a, b)
            .execute()
        )
        for row in rows:
            uid = row["user_id"]
            if uid in state:
                continue
            if needed_user_ids is not None and uid not in needed_user_ids:
                continue
            carry = row.get("carry_forward_balance")
            total = row.get("profit_loss")
            state[uid] = (
                to_decimal(carry) if carry is not None else ZERO,
                to_decimal(total) if total is not None else ZERO,
            )
    return state


def previous_balances(
    db: Client,
    owner_id: str,
    before_report: Optional[dict] = None,
    needed_user_ids: Optional[Set[str]] = None,
) -> Dict[str, Decimal]:
    """Each user's carried-forward balance from their most recent earlier
    calculated period (see previous_state)."""
    return {uid: carry for uid, (carry, _total) in previous_state(db, owner_id, before_report, needed_user_ids).items()}


def _opt(value) -> Optional[float]:
    """None stays None (a week calculated before weekly differences existed)."""
    return None if value is None else float(value)


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
    reports = {r["id"]: r for r in list_reports(db, owner_id)}
    names = {rid: r.get("file_name") for rid, r in reports.items()}
    return [
        HistoryEntry(
            history_id=r["id"],
            run_id=r["run_id"],
            report_id=r["report_id"],
            report_file_name=names.get(r["report_id"]),
            period_start=(reports.get(r["report_id"]) or {}).get("period_start"),
            period_end=(reports.get(r["report_id"]) or {}).get("period_end"),
            calculated_at=r["calculated_at"],
            profit_loss=float(r["profit_loss"]),
            previous_report_total=_opt(r.get("previous_report_total")),
            weekly_change=_opt(r.get("weekly_change")),
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


_MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]


def week_label(report: dict) -> str:
    """'5-11 Oct 2026' (or '28 Sep - 4 Oct 2026'); '' for a legacy report with no dates."""
    try:
        s = date.fromisoformat(str(report.get("period_start")))
        e = date.fromisoformat(str(report.get("period_end")))
    except ValueError:
        return ""
    if (s.year, s.month) == (e.year, e.month):
        return f"{s.day}-{e.day} {_MONTHS[e.month - 1]} {e.year}"
    if s.year == e.year:
        return f"{s.day} {_MONTHS[s.month - 1]} - {e.day} {_MONTHS[e.month - 1]} {e.year}"
    return f"{s.day} {_MONTHS[s.month - 1]} {s.year} - {e.day} {_MONTHS[e.month - 1]} {e.year}"


def get_weeks(db: Client, owner_id: str, user_id: str) -> List[WeekEntry]:
    """The user's weekly bonus ledger: ONE row per completed weekly report
    (from bonus_results, which holds exactly one row per user per report), newest
    week first. Unlike calculation_history this never lists a recalculation twice."""
    reports = {r["id"]: r for r in list_reports(db, owner_id) if r.get("status") == "completed"}
    rows = fetch_all(
        lambda a, b: db.table("bonus_results")
        .select(
            "id, report_id, profit_loss, previous_report_total, weekly_change, bonus_basis, personal_adjustment, referral_adjustment, previous_balance, "
            "final_balance, payable_bonus, carry_forward_balance, calculated_at, whatsapp_send_status"
        )
        .eq("owner_id", owner_id)
        .eq("user_id", user_id)
        .eq("calculation_status", "calculated")
        .order("id")
        .range(a, b)
        .execute()
    )
    rows = [r for r in rows if r["report_id"] in reports]
    rows.sort(key=lambda r: report_sort_key(reports[r["report_id"]]), reverse=True)
    weeks: List[WeekEntry] = []
    for i, r in enumerate(rows):
        rep = reports[r["report_id"]]

        def num(key: str) -> float:
            return float(r.get(key) or 0)

        weeks.append(
            WeekEntry(
                report_id=r["report_id"],
                bonus_result_id=r["id"],
                report_file_name=rep.get("file_name"),
                period_start=rep.get("period_start"),
                period_end=rep.get("period_end"),
                week_label=week_label(rep),
                is_current=i == 0,
                calculated_at=r.get("calculated_at"),
                profit_loss=num("profit_loss"),
                current_report_total=num("profit_loss"),
                previous_report_total=_opt(r.get("previous_report_total")),
                weekly_change=_opt(r.get("weekly_change")),
                bonus_basis=_opt(r.get("bonus_basis")),
                personal_adjustment=num("personal_adjustment"),
                referral_adjustment=num("referral_adjustment"),
                previous_balance=num("previous_balance"),
                final_balance=num("final_balance"),
                payable_bonus=num("payable_bonus"),
                carry_forward_balance=num("carry_forward_balance"),
                send_status=r.get("whatsapp_send_status") or "pending",
            )
        )
    return weeks
