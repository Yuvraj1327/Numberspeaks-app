"""DELETE /reports/{id}: ownership, cascade, storage, carry-forward safety."""

import pytest

from tests.fake_supabase import FakeAPIError

ROWS = [("Boss", -1000), ("R1", -2000), ("Sam", 10000)]


def _count(db, table, rid):
    return sum(1 for r in db.tables.get(table, []) if r.get("report_id") == rid)


def test_delete_removes_report_children_and_pdf_but_keeps_other_data(a, fake_db):
    keep, _ = a.run_week([("Zed", -500)], "keep.pdf")
    rid = a.upload(ROWS, "gone.pdf").json()["report_id"]
    rows = a.results(rid)
    a.post(f"/reports/{rid}/referrals", json={
        "referrer_user_id": rows["Boss"]["user_id"], "referred_user_id": rows["R1"]["user_id"]})
    assert a.calculate(rid).status_code == 200
    assert any(k.startswith(f"{rid}/") for k in fake_db.files["reports"])

    assert a.delete(f"/reports/{rid}").status_code == 204

    assert a.get(f"/reports/{rid}").status_code == 404
    for table in ("bonus_results", "referral_entries", "calculation_history"):
        assert _count(fake_db, table, rid) == 0
    assert not any(k.startswith(f"{rid}/") for k in fake_db.files["reports"])
    # Unrelated report, its rows, its PDF and the shared users survive.
    assert [r["report_id"] for r in a.get("/reports").json()] == [keep]
    assert "Zed" in a.results(keep)
    assert any(k.startswith(f"{keep}/") for k in fake_db.files["reports"])
    assert len(a.get("/users").json()) == 4


def test_other_admin_cannot_delete_and_nothing_is_lost(a, b, fake_db):
    rid = a.upload(ROWS, "a.pdf").json()["report_id"]
    assert b.delete(f"/reports/{rid}").status_code == 404
    assert a.get(f"/reports/{rid}").status_code == 200
    assert _count(fake_db, "bonus_results", rid) == 3
    assert any(k.startswith(f"{rid}/") for k in fake_db.files["reports"])


def test_invalid_or_unknown_id_is_404(a):
    assert a.delete("/reports/not-a-uuid").status_code == 404
    assert a.delete("/reports/00000000-0000-0000-0000-000000000000").status_code == 404


def test_requires_login(client):
    assert client.delete("/api/v1/reports/00000000-0000-0000-0000-000000000000").status_code == 401


def test_older_calculated_report_is_protected_by_newer_one(a):
    old, _ = a.run_week([("Boss", -1000)], "old.pdf")
    new, _ = a.run_week([("Boss", -2000)], "new.pdf")
    blocked = a.delete(f"/reports/{old}")
    assert blocked.status_code == 409
    assert "new.pdf" in blocked.json()["detail"] and "Delete the newer report first" in blocked.json()["detail"]
    assert a.get(f"/reports/{old}").status_code == 200
    assert a.delete(f"/reports/{new}").status_code == 204
    assert a.delete(f"/reports/{old}").status_code == 204  # now newest


def test_database_failure_keeps_everything(a, fake_db):
    rid = a.upload(ROWS, "a.pdf").json()["report_id"]
    fake_db.fail_on = lambda table, mode: table == "reports" and mode == "delete"
    with pytest.raises(FakeAPIError):  # the real PostgREST APIError becomes a 503 in main.py
        a.delete(f"/reports/{rid}")
    fake_db.fail_on = None
    assert a.get(f"/reports/{rid}").status_code == 200
    assert _count(fake_db, "bonus_results", rid) == 3
    assert any(k.startswith(f"{rid}/") for k in fake_db.files["reports"])


def test_storage_failure_still_deletes_the_report(a, fake_db):
    rid = a.upload(ROWS, "a.pdf").json()["report_id"]
    fake_db.storage_fails = True
    assert a.delete(f"/reports/{rid}").status_code == 204
    assert a.get(f"/reports/{rid}").status_code == 404


def test_repeated_delete_is_a_clean_404_and_busy_delete_is_explained(a):
    from app.services.report_locks import report_busy_guard

    rid = a.upload(ROWS, "a.pdf").json()["report_id"]
    with report_busy_guard(rid, "deletion"):
        busy = a.delete(f"/reports/{rid}")
    assert busy.status_code == 409 and "is busy" in busy.json()["detail"]
    assert a.delete(f"/reports/{rid}").status_code == 204
    assert a.delete(f"/reports/{rid}").status_code == 404
