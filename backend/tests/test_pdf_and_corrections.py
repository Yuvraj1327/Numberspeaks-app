"""PDF extraction (multi-page), review/correction before confirming, persistence."""

import pytest

from tests.conftest import build_pdf


def test_extracts_all_columns_from_a_single_page(a):
    r = a.upload([("Rahul", -1000), ("Priya", 500.5)])
    assert r.status_code == 200, r.text
    body = r.json()
    assert body["status"] == "processing"
    assert body["total_records"] == 2
    rec = {x["user_name"]: x for x in body["records"]}
    assert rec["Rahul"]["profit_loss"] == -1000
    assert rec["Rahul"]["level"] == "Gold"
    assert rec["Rahul"]["casino_pts"] == 10 and rec["Rahul"]["sport_pts"] == 5 and rec["Rahul"]["third_party_pts"] == 1
    assert rec["Rahul"]["ptype"] == "User"
    assert rec["Priya"]["profit_loss"] == 500.5


def test_any_number_of_pages_is_read(a):
    rows = [(f"user{i:03d}", -(i + 1) * 10) for i in range(120)]
    r = a.upload(rows, rows_per_page=30)  # 4 pages, header repeated on each
    assert r.status_code == 200, r.text
    body = r.json()
    assert body["pages_processed"] == 4
    assert body["total_records"] == 120
    assert {x["user_name"] for x in body["records"]} == {n for n, _ in rows}


def test_more_than_1000_rows_are_all_saved_and_returned(a):
    """PostgREST returns at most 1000 rows per request — nothing may be cut off."""
    rows = [(f"u{i:05d}", -100) for i in range(1105)]
    r = a.upload(rows, rows_per_page=60)
    assert r.status_code == 200, r.text
    rid = r.json()["report_id"]
    assert r.json()["total_records"] == 1105
    assert len(a.results(rid)) == 1105


def test_results_are_persisted_and_readable_again(a):
    rid = a.upload([("Rahul", -1000)]).json()["report_id"]
    again = a.get(f"/reports/{rid}/results")
    assert again.status_code == 200 and len(again.json()) == 1
    assert again.json()[0]["calculation_status"] == "pending"
    assert again.json()[0]["bonus_amount"] is None  # nothing guessed before the admin confirms


def test_non_pdf_and_empty_and_corrupt_uploads_are_rejected(a, fake_db):
    assert a.post("/reports/upload", files={"file": ("x.txt", b"hello", "text/plain")}).status_code == 400
    assert a.post("/reports/upload", files={"file": ("x.pdf", b"", "application/pdf")}).status_code == 400
    bad = a.post("/reports/upload", files={"file": ("x.pdf", b"not really a pdf", "application/pdf")})
    assert bad.status_code in (400, 422)
    assert fake_db.tables.get("reports", []) == []  # nothing was created for a bad upload


def test_storage_failure_marks_report_failed_and_reports_502(a, fake_db):
    fake_db.storage_fails = True
    r = a.post("/reports/upload", files={"file": ("w.pdf", build_pdf([("A", -100)]), "application/pdf")})
    assert r.status_code == 502
    assert fake_db.tables["reports"][0]["status"] == "failed"


def test_duplicate_user_in_pdf_is_kept_once_with_a_warning(a):
    r = a.upload([("Rahul", -1000), ("Rahul", -500)])
    assert r.status_code == 200, r.text
    assert r.json()["total_records"] == 1
    assert any("Rahul" in w for w in r.json()["warnings"])


# --- manual corrections ------------------------------------------------------
def test_admin_can_correct_a_misread_value_before_calculating(a):
    rid = a.upload([("Rahul", -1000), ("Amit", 200)]).json()["report_id"]
    rows = a.results(rid)
    fix = a.patch(f"/reports/{rid}/rows/{rows['Rahul']['bonus_result_id']}", json={"profit_loss": -2000, "level": "Silver", "ptype": "Agent"})
    assert fix.status_code == 200, fix.text
    assert fix.json()["profit_loss"] == -2000 and fix.json()["level"] == "Silver" and fix.json()["ptype"] == "Agent"

    calc = a.calculate(rid).json()
    by = {r["user_name"]: r for r in calc["results"]}
    assert by["Rahul"]["payable_bonus"] == 60.0  # 3% of the CORRECTED 2000 loss
    assert by["Rahul"]["profit_loss"] == -2000


def test_correcting_the_name_moves_the_row_to_that_user(a):
    rid = a.upload([("Rahull", -1000)]).json()["report_id"]  # misread name
    row = a.results(rid)["Rahull"]
    fix = a.patch(f"/reports/{rid}/rows/{row['bonus_result_id']}", json={"user_name": "Rahul"})
    assert fix.status_code == 200, fix.text
    assert fix.json()["user_name"] == "Rahul"
    assert set(a.results(rid)) == {"Rahul"}


def test_renaming_onto_another_row_of_the_same_report_is_refused(a):
    rid = a.upload([("A", -100), ("B", -100)]).json()["report_id"]
    rows = a.results(rid)
    r = a.patch(f"/reports/{rid}/rows/{rows['A']['bonus_result_id']}", json={"user_name": "B"})
    assert r.status_code == 409


@pytest.mark.parametrize("payload", [{"profit_loss": "abc"}, {"casino_pts": "12x"}, {"profit_loss": None}, {"user_name": "  "}])
def test_bad_corrections_are_rejected(a, payload):
    rid = a.upload([("A", -100)]).json()["report_id"]
    row = a.results(rid)["A"]
    r = a.patch(f"/reports/{rid}/rows/{row['bonus_result_id']}", json=payload)
    assert r.status_code == 422, r.text
    assert a.results(rid)["A"]["profit_loss"] == -100  # unchanged


def test_correcting_a_calculated_row_reopens_the_report_for_recalculation(a):
    rid, res = a.run_week([("A", -1000)])
    assert a.get(f"/reports/{rid}").json()["status"] == "completed"
    r = a.patch(f"/reports/{rid}/rows/{res['A']['bonus_result_id']}", json={"profit_loss": -3000})
    assert r.status_code == 200
    assert r.json()["calculation_status"] == "pending" and a.get(f"/reports/{rid}").json()["status"] == "processing"
    # cannot calculate straight away — it must be validated again (the admin confirms)
    assert a.post(f"/reports/{rid}/calculate-bonus").status_code == 409
    assert a.calculate(rid).json()["results"][0]["payable_bonus"] == 90.0


def test_editing_only_the_whatsapp_number_does_not_invalidate_the_calculation(a):
    rid, res = a.run_week([("A", -1000)])
    r = a.patch(f"/reports/{rid}/rows/{res['A']['bonus_result_id']}", json={"whatsapp_number": "+91 98765 43210"})
    assert r.status_code == 200
    assert r.json()["calculation_status"] == "calculated" and r.json()["whatsapp_number"] == "+919876543210"
    assert a.get(f"/reports/{rid}").json()["status"] == "completed"


def test_cannot_calculate_before_validating(a):
    rid = a.upload([("A", -100)]).json()["report_id"]
    assert a.post(f"/reports/{rid}/calculate-bonus").status_code == 409
