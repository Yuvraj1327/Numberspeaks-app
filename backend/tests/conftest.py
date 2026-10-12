"""
Shared test fixtures.

The real FastAPI app is used end to end. Only two things are swapped:
  * `get_db`          -> an in-memory FakeSupabase (tests/fake_supabase.py)
  * `get_current_user`-> reads the caller from an `X-Test-User` header, so a
                         single test can act as admin A and admin B.
The real token check is covered separately in test_auth.py.
"""

import io
import os
import sys
from typing import List, Optional, Sequence, Tuple

import pytest

# Make `import app...` work no matter where pytest is started from.
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
if ROOT not in sys.path:
    sys.path.insert(0, ROOT)

from fastapi import HTTPException, Request  # noqa: E402
from fastapi.testclient import TestClient  # noqa: E402
from reportlab.lib import colors  # noqa: E402
from reportlab.lib.pagesizes import letter  # noqa: E402
from reportlab.platypus import SimpleDocTemplate, Table, TableStyle  # noqa: E402

from app.api.deps import get_current_user, get_db  # noqa: E402
from app.core.auth import CurrentUser  # noqa: E402
from app.main import app  # noqa: E402
from tests.fake_supabase import FakeSupabase  # noqa: E402

ADMIN_A = "00000000-0000-4000-8000-00000000000a"
ADMIN_B = "00000000-0000-4000-8000-00000000000b"

HEADERS = ["No", "User Name", "WhatsApp Number", "Level", "Casino Pts", "Sport Pts", "Third Party Pts", "Profit/Loss", "Ptype"]

# (name, profit_loss) — everything else is filler.
Row = Tuple[str, float]


def build_pdf(rows: Sequence[Row], rows_per_page: Optional[int] = None) -> bytes:
    """A 'Party Profit Loss' style PDF. With `rows_per_page`, the table is
    split so the PDF genuinely has several pages (each with its own header)."""
    data_rows = [
        [str(i + 1), name, "", "Gold", "10.00", "5.00", "1.00", f"{pl:.2f}", "User"]
        for i, (name, pl) in enumerate(rows)
    ]
    chunks: List[List[List[str]]] = []
    if rows_per_page:
        for i in range(0, len(data_rows), rows_per_page):
            chunks.append(data_rows[i : i + rows_per_page])
    else:
        chunks.append(data_rows)

    buf = io.BytesIO()
    doc = SimpleDocTemplate(buf, pagesize=letter, leftMargin=20, rightMargin=20, topMargin=20, bottomMargin=20)
    story = []
    from reportlab.platypus import PageBreak

    for idx, chunk in enumerate(chunks):
        table = Table([HEADERS] + chunk, repeatRows=1)
        table.setStyle(
            TableStyle(
                [
                    ("GRID", (0, 0), (-1, -1), 0.5, colors.black),
                    ("FONTSIZE", (0, 0), (-1, -1), 7),
                ]
            )
        )
        story.append(table)
        if idx < len(chunks) - 1:
            story.append(PageBreak())
    doc.build(story)
    return buf.getvalue()


class Api:
    """Thin helper around TestClient that acts as a chosen admin."""

    def __init__(self, client: TestClient, user_id: str):
        self.c = client
        self.h = {"X-Test-User": user_id}
        self.user_id = user_id

    def get(self, url, **kw):
        return self.c.get("/api/v1" + url, headers=self.h, **kw)

    def post(self, url, **kw):
        return self.c.post("/api/v1" + url, headers=self.h, **kw)

    def patch(self, url, **kw):
        return self.c.patch("/api/v1" + url, headers=self.h, **kw)

    def put(self, url, **kw):
        return self.c.put("/api/v1" + url, headers=self.h, **kw)

    def delete(self, url, **kw):
        return self.c.delete("/api/v1" + url, headers=self.h, **kw)

    # --- workflow helpers --------------------------------------------------
    def upload(self, rows: Sequence[Row], name: str = "week.pdf", rows_per_page: Optional[int] = None):
        pdf = build_pdf(rows, rows_per_page)
        return self.post("/reports/upload", files={"file": (name, pdf, "application/pdf")})

    def results(self, report_id: str):
        r = self.get(f"/reports/{report_id}/results")
        assert r.status_code == 200, r.text
        return {row["user_name"]: row for row in r.json()}

    def calculate(self, report_id: str):
        v = self.post(f"/reports/{report_id}/validate")
        assert v.status_code == 200, v.text
        assert v.json()["status"] == "validated", v.text
        return self.post(f"/reports/{report_id}/calculate-bonus")

    def run_week(self, rows: Sequence[Row], name: str = "week.pdf"):
        """Upload + validate + calculate; returns (report_id, results-by-name)."""
        up = self.upload(rows, name)
        assert up.status_code == 200, up.text
        report_id = up.json()["report_id"]
        calc = self.calculate(report_id)
        assert calc.status_code == 200, calc.text
        assert calc.json()["status"] == "completed", calc.text
        return report_id, {r["user_name"]: r for r in calc.json()["results"]}


@pytest.fixture()
def fake_db() -> FakeSupabase:
    return FakeSupabase()


@pytest.fixture()
def client(fake_db):
    def _db():
        return fake_db

    def _user(request: Request) -> CurrentUser:
        uid = request.headers.get("x-test-user")
        if not uid:
            raise HTTPException(status_code=401, detail="no test user")
        return CurrentUser(id=uid, email=f"{uid}@example.com")

    app.dependency_overrides[get_db] = _db
    app.dependency_overrides[get_current_user] = _user
    try:
        yield TestClient(app, raise_server_exceptions=True)
    finally:
        app.dependency_overrides.clear()


@pytest.fixture()
def a(client) -> Api:
    return Api(client, ADMIN_A)


@pytest.fixture()
def b(client) -> Api:
    return Api(client, ADMIN_B)
