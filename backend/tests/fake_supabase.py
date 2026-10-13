"""
A small in-memory stand-in for the Supabase (PostgREST) client.

It implements only the query-builder surface this backend uses —
table().select/insert/update/upsert/delete with eq/neq/gt/lt/in_/ilike,
order, range, limit, the embedded `users(...)` join, unique constraints and
a fake storage bucket — so the real endpoints and services can be exercised
end to end without a network or a Supabase project.

It is NOT Postgres: it cannot prove SQL, RLS, or real PostgREST behaviour.
It exists to test this app's own logic (ownership scoping, calculation,
carry-forward, duplicate prevention, ...).
"""

import copy
import itertools
from datetime import datetime, timedelta, timezone
from types import SimpleNamespace
from typing import Any, Dict, List, Optional
from uuid import uuid4


class FakeAPIError(Exception):
    def __init__(self, message: str, code: str):
        super().__init__(message)
        self.code = code


_BASE = datetime(2026, 1, 1, tzinfo=timezone.utc)
_clock = itertools.count(1)


def _now() -> str:
    return (_BASE + timedelta(seconds=next(_clock))).isoformat()


# table -> list of unique column tuples; a (cols, partial_not_null_col) pair
# means "unique only where that column is not null".
UNIQUES: Dict[str, List[Any]] = {
    "users": [(("owner_id", "name"), "owner_id")],
    "bonus_results": [(("report_id", "user_id"), None)],
    "referral_entries": [(("owner_id", "report_id", "referred_user_id"), None)],
    "bonus_settings": [(("owner_id",), None)],
    "referrers": [(("owner_id", "user_id"), None)],
    # mirrors uq_whatsapp_sends_one_active (partial: only sending/sent rows)
    "whatsapp_sends": [(("bonus_result_id",), lambda r: r.get("status") in ("sending", "sent"))],
}

DEFAULTS: Dict[str, Dict[str, Any]] = {
    "users": {"level": None, "whatsapp_number": None, "is_active": True, "owner_id": None},
    "reports": {"status": "uploaded", "file_path": "", "user_count": None, "payable_user_count": None,
                "total_payable": None, "calculated_at": None, "owner_id": None},
    "bonus_results": {"casino_pts": 0, "sport_pts": 0, "third_party_pts": 0, "profit_loss": 0, "ptype": None,
                      "bonus_amount": None, "calculation_status": "pending", "owner_id": None,
                      "personal_rate_used": None, "personal_adjustment": None, "referral_adjustment": None,
                      "previous_balance": None, "final_balance": None, "payable_bonus": None,
                      "carry_forward_balance": None, "calculated_at": None,
                      "whatsapp_send_status": "pending", "whatsapp_send_error": None,
                      "whatsapp_sent_at": None},
    "referral_entries": {"amount": None, "adjustment": None, "calculated_at": None},
    "referrers": {"display_name": None, "notes": None, "default_rate": None, "is_active": True},
    "calculation_history": {},
    "whatsapp_initiations": {},
    "whatsapp_sends": {"provider_message_id": None, "error_message": None, "batch_id": None},
    "whatsapp_batches": {"skipped": [], "finished_at": None},
    "whatsapp_test_sends": {"provider_message_id": None, "error_message": None},
    "bonus_settings": {},
}

PK = {"bonus_settings": "owner_id"}


class FakeResponse(SimpleNamespace):
    pass


class FakeQuery:
    def __init__(self, db: "FakeSupabase", table: str):
        self.db = db
        self.table_name = table
        self.mode = "select"
        self.payload: Any = None
        self.on_conflict: Optional[str] = None
        self.filters: List[Any] = []
        self.orders: List[Any] = []
        self.range_: Optional[tuple] = None
        self.limit_: Optional[int] = None
        self.select_cols = "*"

    # --- builders -----------------------------------------------------------
    def select(self, cols: str = "*", count: Optional[str] = None):
        self.mode = "select"
        self.select_cols = cols
        return self

    def insert(self, payload):
        self.mode = "insert"
        self.payload = payload
        return self

    def update(self, values):
        self.mode = "update"
        self.payload = values
        return self

    def upsert(self, payload, on_conflict: Optional[str] = None):
        self.mode = "upsert"
        self.payload = payload
        self.on_conflict = on_conflict
        return self

    def delete(self):
        self.mode = "delete"
        return self

    def eq(self, col, val):
        self.filters.append(lambda r, c=col, v=val: r.get(c) == v)
        return self

    def neq(self, col, val):
        self.filters.append(lambda r, c=col, v=val: r.get(c) != v)
        return self

    def gt(self, col, val):
        self.filters.append(lambda r, c=col, v=val: r.get(c) is not None and r.get(c) > v)
        return self

    def lt(self, col, val):
        self.filters.append(lambda r, c=col, v=val: r.get(c) is not None and r.get(c) < v)
        return self

    def in_(self, col, values):
        vals = set(values)
        self.filters.append(lambda r, c=col: r.get(c) in vals)
        return self

    def ilike(self, col, pattern):
        needle = pattern.strip("%").lower()
        self.filters.append(lambda r, c=col: needle in str(r.get(c) or "").lower())
        return self

    def order(self, col, desc: bool = False):
        self.orders.append((col, desc))
        return self

    def range(self, start, end):
        self.range_ = (start, end)
        return self

    def limit(self, n):
        self.limit_ = n
        return self

    # --- execution ---------------------------------------------------------
    def _rows(self) -> List[dict]:
        return self.db.tables.setdefault(self.table_name, [])

    def _matching(self) -> List[dict]:
        rows = [r for r in self._rows() if all(f(r) for f in self.filters)]
        for col, desc in reversed(self.orders):
            rows.sort(key=lambda r, c=col: ("" if r.get(c) is None else r.get(c)), reverse=desc)
        if self.range_ is not None:
            a, b = self.range_
            rows = rows[a : b + 1]
        if self.limit_ is not None:
            rows = rows[: self.limit_]
        return rows

    def _check_unique(self, candidate: dict, ignore: Optional[dict] = None) -> None:
        for cols, partial in UNIQUES.get(self.table_name, []):
            if callable(partial):
                if not partial(candidate):
                    continue
            elif partial and candidate.get(partial) is None:
                continue
            key = tuple(candidate.get(c) for c in cols)
            for existing in self._rows():
                if existing is ignore:
                    continue
                if callable(partial) and not partial(existing):
                    continue
                if tuple(existing.get(c) for c in cols) == key:
                    raise FakeAPIError(
                        f'duplicate key value violates unique constraint on {self.table_name}{cols}', "23505"
                    )

    def _new_row(self, values: dict) -> dict:
        row = {"id": str(uuid4())}
        row.update(copy.deepcopy(DEFAULTS.get(self.table_name, {})))
        if self.table_name == "reports":
            row["uploaded_at"] = _now()
        else:
            row["created_at"] = _now()
        row.update(copy.deepcopy(values))
        if self.table_name == "referral_entries" and row.get("referrer_user_id") == row.get("referred_user_id"):
            raise FakeAPIError("check constraint referral_entries_not_self", "23514")
        if self.table_name == "bonus_settings":
            row.pop("id", None)
        return row

    def _embed(self, row: dict) -> dict:
        out = copy.deepcopy(row)
        if "users(" in self.select_cols and "user_id" in row:
            user = next((u for u in self.db.tables.get("users", []) if u["id"] == row["user_id"]), None)
            out["users"] = copy.deepcopy(user) if user else None
        return out

    def execute(self) -> FakeResponse:
        if self.db.fail_on and self.db.fail_on(self.table_name, self.mode):
            raise FakeAPIError("simulated failure", "XX000")

        if self.mode == "select":
            return FakeResponse(data=[self._embed(r) for r in self._matching()], count=None)

        if self.mode == "insert":
            items = self.payload if isinstance(self.payload, list) else [self.payload]
            staged = []
            # Postgres makes a multi-row insert atomic: all rows or none.
            existing_snapshot = list(self._rows())
            try:
                for item in items:
                    row = self._new_row(item)
                    self._check_unique(row)
                    self._rows().append(row)
                    staged.append(row)
            except FakeAPIError:
                self.db.tables[self.table_name] = existing_snapshot
                raise
            return FakeResponse(data=[copy.deepcopy(r) for r in staged], count=None)

        if self.mode == "update":
            updated = []
            for row in self._matching():
                candidate = {**row, **copy.deepcopy(self.payload)}
                self._check_unique(candidate, ignore=row)
                row.update(copy.deepcopy(self.payload))
                updated.append(copy.deepcopy(row))
            return FakeResponse(data=updated, count=None)

        if self.mode == "upsert":
            items = self.payload if isinstance(self.payload, list) else [self.payload]
            conflict_cols = [c.strip() for c in (self.on_conflict or PK.get(self.table_name, "id")).split(",")]
            out = []
            for item in items:
                match = next(
                    (r for r in self._rows() if all(r.get(c) == item.get(c) for c in conflict_cols)), None
                )
                if match:
                    match.update(copy.deepcopy(item))
                    out.append(copy.deepcopy(match))
                else:
                    row = self._new_row(item)
                    self._check_unique(row)
                    self._rows().append(row)
                    out.append(copy.deepcopy(row))
            return FakeResponse(data=out, count=None)

        if self.mode == "delete":
            doomed = self._matching()
            self.db.tables[self.table_name] = [r for r in self._rows() if r not in doomed]
            return FakeResponse(data=[copy.deepcopy(r) for r in doomed], count=None)

        raise AssertionError(self.mode)


class _Bucket:
    def __init__(self, store: Dict[str, bytes], fail: bool):
        self.store = store
        self.fail = fail

    def upload(self, path, data, options=None):
        if self.fail:
            raise RuntimeError("bucket does not exist")
        self.store[path] = data

    def remove(self, paths):
        if self.fail:
            raise RuntimeError("storage unavailable")
        for path in paths:
            self.store.pop(path, None)


class _Storage:
    def __init__(self, db: "FakeSupabase"):
        self.db = db

    def from_(self, bucket: str):
        return _Bucket(self.db.files.setdefault(bucket, {}), self.db.storage_fails)


class FakeSupabase:
    def __init__(self):
        self.tables: Dict[str, List[dict]] = {}
        self.files: Dict[str, Dict[str, bytes]] = {}
        self.storage_fails = False
        self.fail_on = None  # optional callable(table, mode) -> bool
        self.storage = _Storage(self)

    def table(self, name: str) -> FakeQuery:
        return FakeQuery(self, name)
