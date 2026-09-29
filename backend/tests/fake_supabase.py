"""
In-memory stand-in for the supabase-py client, for tests only.

It implements just the query-builder calls the app uses, and mimics the
database behaviour the pipeline depends on: PostgREST's 1000-row cap per
read, the unique (report_id, user_id) constraint, the reports.status check
constraint, the updated_at trigger, and upsert-merges-only-given-columns.
Every .execute() counts as one request, like one HTTP call to Supabase.
"""

import re
import threading
import time
import uuid
from collections import Counter
from datetime import datetime, timezone

MAX_ROWS = 1000
REPORT_STATUSES = {
    "uploaded", "processing", "validating", "calculating", "validated", "completed", "failed",
}


class FakeAPIError(Exception):
    def __init__(self, code, message="error"):
        super().__init__(message)
        self.code = code


def _now():
    return datetime.now(timezone.utc).isoformat()


class _Result:
    def __init__(self, data):
        self.data = data


class _Query:
    def __init__(self, db, table):
        self.db, self.table = db, table
        self.op = "select"
        self.payload = None
        self.on_conflict = None
        self.filters = []
        self.orders = []
        self.rng = None
        self.lim = None
        self.select_cols = "*"

    # --- builders ---
    def select(self, cols="*"):
        self.op, self.select_cols = "select", cols
        return self

    def insert(self, payload):
        self.op, self.payload = "insert", payload
        return self

    def upsert(self, payload, on_conflict="", **_):
        self.op, self.payload, self.on_conflict = "upsert", payload, on_conflict
        return self

    def update(self, payload):
        self.op, self.payload = "update", payload
        return self

    def eq(self, col, val):
        self.filters.append((col, "eq", val))
        return self

    def filter(self, col, op, val):
        self.filters.append((col, op, val))
        return self

    def order(self, col, desc=False):
        self.orders.append((col, desc))
        return self

    def range(self, a, b):
        self.rng = (a, b)
        return self

    def limit(self, n):
        self.lim = n
        return self

    # --- execution ---
    def execute(self):
        return self.db._execute(self)


def _parse_in(value):
    inner = value[1:-1]
    items, cur, quoted, esc = [], "", False, False
    for ch in inner:
        if esc:
            cur += ch
            esc = False
        elif quoted and ch == "\\":
            esc = True
        elif ch == '"':
            quoted = not quoted
        elif ch == "," and not quoted:
            items.append(cur)
            cur = ""
        else:
            cur += ch
    items.append(cur)
    return items


class FakeSupabase:
    def __init__(self, latency=0.0):
        self.tables = {"users": [], "reports": [], "bonus_results": [], "whatsapp_messages": []}
        self.files = {}
        self.requests = Counter()
        self.latency = latency
        self.lock = threading.RLock()
        self.status_history = {}  # report_id -> ordered distinct statuses
        self.fail_next = []  # (table, op) pairs to fail once

    # supabase-py surface
    def table(self, name):
        return _Query(self, name)

    @property
    def storage(self):
        return _Storage(self)

    # helpers
    def _match(self, row, filters):
        for col, op, val in filters:
            if op == "eq":
                if str(row.get(col)) != str(val):
                    return False
            elif op == "in":
                if str(row.get(col)) not in _parse_in(val):
                    return False
            else:
                raise NotImplementedError(op)
        return True

    def _check_report(self, row):
        if row.get("status") not in REPORT_STATUSES:
            raise FakeAPIError("23514", "reports_status_check violated")
        rec = self.status_history.setdefault(row["id"], [])
        if not rec or rec[-1] != row["status"]:
            rec.append(row["status"])

    def _project(self, table, row, cols):
        out = dict(row)
        if table == "bonus_results":
            if "users(" in cols:
                user = next((u for u in self.tables["users"] if u["id"] == row["user_id"]), None)
                out["users"] = (
                    {k: user[k] for k in ("id", "name", "level", "whatsapp_number")} if user else None
                )
            if "whatsapp_messages(" in cols:
                out["whatsapp_messages"] = [
                    {"status": m["status"], "created_at": m["created_at"]}
                    for m in self.tables["whatsapp_messages"]
                    if m["bonus_result_id"] == row["id"]
                ]
        return out

    def _execute(self, q):
        if self.latency:
            time.sleep(self.latency)
        with self.lock:
            self.requests[(q.table, q.op)] += 1
            key = (q.table, q.op)
            if key in self.fail_next:
                self.fail_next.remove(key)
                raise FakeAPIError("XX000", "injected failure")
            rows = self.tables[q.table]

            if q.op == "select":
                found = [r for r in rows if self._match(r, q.filters)]
                for col, desc in reversed(q.orders):
                    found.sort(key=lambda r: str(r.get(col)), reverse=desc)
                if q.rng:
                    found = found[q.rng[0]: q.rng[1] + 1]
                cap = min(MAX_ROWS, q.lim) if q.lim else MAX_ROWS
                return _Result([self._project(q.table, r, q.select_cols) for r in found[:cap]])

            if q.op == "insert":
                items = q.payload if isinstance(q.payload, list) else [q.payload]
                created = [self._insert_one(q.table, dict(i)) for i in items]
                return _Result([dict(c) for c in created])

            if q.op == "upsert":
                items = q.payload if isinstance(q.payload, list) else [q.payload]
                keys = [c.strip() for c in q.on_conflict.split(",")]
                out = []
                for item in items:
                    existing = next(
                        (r for r in rows if all(r.get(k) == item.get(k) for k in keys)), None
                    )
                    if existing:
                        existing.update(item)  # only the given columns
                        if q.table == "reports":
                            existing["updated_at"] = _now()
                        out.append(dict(existing))
                    else:
                        out.append(dict(self._insert_one(q.table, dict(item))))
                return _Result(out)

            if q.op == "update":
                hit = [r for r in rows if self._match(r, q.filters)]
                for r in hit:
                    r.update(q.payload)
                    if q.table == "reports":
                        r["updated_at"] = _now()
                        self._check_report(r)
                return _Result([dict(r) for r in hit])

    def _insert_one(self, table, row):
        rows = self.tables[table]
        row.setdefault("id", str(uuid.uuid4()))
        row.setdefault("created_at", _now())
        if table == "reports":
            row.setdefault("status", "uploaded")
            row.setdefault("attempts", 0)
            row.setdefault("pages_processed", 0)
            row.setdefault("total_records", 0)
            row.setdefault("calculated_count", 0)
            row.setdefault("failed_count", 0)
            row.setdefault("warnings", [])
            row.setdefault("error_message", None)
            row["uploaded_at"] = row["updated_at"] = _now()
            self._check_report(row)
        if table == "users":
            row.setdefault("is_active", True)
            if row.get("name") is None:
                raise FakeAPIError("23502", "null name")
        if table == "bonus_results":
            for col in ("report_id", "user_id"):
                if row.get(col) is None:
                    raise FakeAPIError("23502", f"null {col}")
            for col in ("casino_pts", "sport_pts", "third_party_pts", "profit_loss"):
                row.setdefault(col, 0)
            row.setdefault("bonus_amount", None)
            row.setdefault("calculation_status", "pending")
            if any(r["report_id"] == row["report_id"] and r["user_id"] == row["user_id"] for r in rows):
                raise FakeAPIError("23505", "bonus_results_report_user_unique")
        if any(r["id"] == row["id"] for r in rows):
            raise FakeAPIError("23505", "pk")
        rows.append(row)
        return row


class _Storage:
    def __init__(self, db):
        self.db = db

    def from_(self, bucket):
        return _Bucket(self.db, bucket)


class _Bucket:
    def __init__(self, db, bucket):
        self.db, self.bucket = db, bucket

    def upload(self, path, data, _opts=None):
        self.db.requests[("storage", "upload")] += 1
        self.db.files[(self.bucket, path)] = bytes(data)

    def download(self, path):
        self.db.requests[("storage", "download")] += 1
        return self.db.files[(self.bucket, path)]

    def remove(self, paths):
        self.db.requests[("storage", "remove")] += 1
        for p in paths:
            self.db.files.pop((self.bucket, p), None)
