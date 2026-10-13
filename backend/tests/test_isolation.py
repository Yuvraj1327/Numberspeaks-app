"""Account-wise data isolation: one admin must never see or change another's data."""

import pytest

from tests.conftest import ADMIN_A, ADMIN_B, build_pdf


@pytest.fixture()
def world(a, b):
    """Admin A has a calculated report with a referral and a saved number."""
    rid = a.upload([("Boss", -1000), ("R1", -2000), ("Sam", 10000)], "a.pdf").json()["report_id"]
    rows = a.results(rid)
    ref = a.post(f"/reports/{rid}/referrals", json={"referrer_user_id": rows["Boss"]["user_id"], "referred_user_id": rows["R1"]["user_id"]}).json()
    a.patch(f"/users/{rows['Boss']['user_id']}", json={"whatsapp_number": "919876543210"})
    res = a.calculate(rid).json()
    return {"rid": rid, "rows": {r["user_name"]: r for r in res["results"]}, "ref": ref}


def test_b_cannot_list_or_read_a_report(world, b):
    rid = world["rid"]
    assert b.get("/reports").json() == []
    assert b.get(f"/reports/{rid}").status_code == 404
    assert b.get(f"/reports/{rid}/results").status_code == 404
    uid = world["rows"]["Boss"]["user_id"]
    assert b.get(f"/reports/{rid}/results/{uid}").status_code == 404


def test_b_cannot_change_or_calculate_a_report(world, b):
    rid, row = world["rid"], world["rows"]["Boss"]
    assert b.patch(f"/reports/{rid}/rows/{row['bonus_result_id']}", json={"profit_loss": 1}).status_code == 404
    assert b.post(f"/reports/{rid}/validate").status_code == 404
    assert b.post(f"/reports/{rid}/calculate-bonus").status_code == 404


def test_b_cannot_touch_a_referral_entries(world, b):
    rid, ref = world["rid"], world["ref"]
    assert b.get(f"/reports/{rid}/referrals").status_code == 404
    assert b.delete(f"/reports/{rid}/referrals/{ref['entry_id']}").status_code == 404
    assert b.post(f"/reports/{rid}/referrals", json={"referrer_user_id": world["rows"]["Boss"]["user_id"], "referred_user_id": world["rows"]["Sam"]["user_id"]}).status_code == 404


def test_b_cannot_see_or_edit_a_users(world, b):
    uid = world["rows"]["Boss"]["user_id"]
    assert b.get("/users").json() == []
    assert b.get(f"/users/{uid}").status_code == 404
    assert b.get(f"/users/{uid}/history").status_code == 404
    assert b.patch(f"/users/{uid}", json={"whatsapp_number": "919000000000"}).status_code == 404


def test_b_cannot_record_whatsapp_for_a_result(world, b):
    rid, row = world["rid"], world["rows"]["Boss"]
    r = b.post(f"/reports/{rid}/results/{row['bonus_result_id']}/whatsapp-send",
               json={"message": "hi"})
    assert r.status_code == 404


def test_a_data_is_untouched_after_b_attacks(world, a, b):
    rid, uid = world["rid"], world["rows"]["Boss"]["user_id"]
    b.patch(f"/users/{uid}", json={"whatsapp_number": "919000000000"})
    b.delete(f"/reports/{rid}/referrals/{world['ref']['entry_id']}")
    b.put("/settings", json={"personal_rate": 0.5})
    assert a.get(f"/users/{uid}").json()["whatsapp_number"] == "919876543210"
    assert len(a.get(f"/reports/{rid}/referrals").json()) == 1
    assert a.get("/settings").json()["personal_rate"] == 0.03
    assert a.get(f"/reports/{rid}").json()["status"] == "completed"


def test_settings_are_per_admin(a, b):
    a.put("/settings", json={"personal_rate": 0.07, "referral_rate": 0.2})
    assert b.get("/settings").json()["personal_rate"] == 0.03 and b.get("/settings").json()["referral_rate"] == 0.10
    _, rb = b.run_week([("L", -1000)])
    assert rb["L"]["personal_adjustment"] == 30.0


def test_same_user_id_for_two_admins_are_two_separate_people(a, b):
    """Both admins have a casino user called 'Rahul' — different people, no shared balance or number."""
    _, ra = a.run_week([("Rahul", 10000)], "a.pdf")      # A: carries -300
    _, rb = b.run_week([("Rahul", -1000)], "b.pdf")      # B must not inherit A's -300
    assert ra["Rahul"]["user_id"] != rb["Rahul"]["user_id"]
    assert rb["Rahul"]["previous_balance"] == 0.0 and rb["Rahul"]["payable_bonus"] == 30.0
    a.patch(f"/users/{ra['Rahul']['user_id']}", json={"whatsapp_number": "919111111111"})
    assert b.get(f"/users/{rb['Rahul']['user_id']}").json()["whatsapp_number"] is None
    assert len(a.get("/reports").json()) == 1 and len(b.get("/reports").json()) == 1


def test_a_newer_report_of_b_does_not_lock_a_older_report(a, b):
    rid_a, _ = a.run_week([("X", -100)], "a.pdf")
    b.run_week([("X", -100)], "b.pdf")  # uploaded later, but another admin
    r = a.post(f"/reports/{rid_a}/validate")
    assert r.status_code == 200  # not blocked by B's report


def test_owner_id_in_a_request_body_is_ignored(a, b, fake_db):
    rid = a.upload([("Boss", 0), ("R1", -1000)]).json()["report_id"]
    rows = a.results(rid)
    r = a.post(f"/reports/{rid}/referrals", json={
        "referrer_user_id": rows["Boss"]["user_id"], "referred_user_id": rows["R1"]["user_id"],
        "owner_id": ADMIN_B,  # must have no effect
    })
    assert r.status_code == 201
    assert fake_db.tables["referral_entries"][0]["owner_id"] == ADMIN_A
    # same for a row correction and settings
    a.patch(f"/reports/{rid}/rows/{rows['Boss']['bonus_result_id']}", json={"owner_id": ADMIN_B, "level": "VIP"})
    a.put("/settings", json={"owner_id": ADMIN_B, "personal_rate": 0.04})
    assert {r["owner_id"] for r in fake_db.tables["bonus_results"]} == {ADMIN_A}
    assert {r["owner_id"] for r in fake_db.tables["users"]} == {ADMIN_A}
    assert [s["owner_id"] for s in fake_db.tables["bonus_settings"]] == [ADMIN_A]
    assert b.get("/settings").json()["personal_rate"] == 0.03


def test_every_row_written_is_stamped_with_the_authenticated_owner(a, fake_db):
    a.run_week([("Boss", 0), ("R1", -1000), ("Sam", 10000)])
    for table in ("reports", "users", "bonus_results", "calculation_history"):
        rows = fake_db.tables[table]
        assert rows, table
        assert {r["owner_id"] for r in rows} == {ADMIN_A}, table


def test_stored_pdf_path_is_per_report_and_reports_are_not_shared(a, b, fake_db):
    a.upload([("A", -1)], "same.pdf")
    b.upload([("A", -1)], "same.pdf")
    assert len(fake_db.files["reports"]) == 2  # different report ids -> different object paths


def test_malformed_ids_are_404_not_500(a):
    assert a.get("/reports/not-a-uuid").status_code == 404
    assert a.get("/reports/not-a-uuid/results").status_code == 404
    assert a.delete("/reports/not-a-uuid/referrals/also-bad").status_code == 404


def test_data_persists_across_logout_and_login(a, client):
    """A new session (new client, same verified user id) sees everything saved before.
    State lives only in the database, never in server memory or the session."""
    from tests.conftest import Api

    rid, res = a.run_week([("Rahul", -1000)])
    a.patch(f"/users/{res['Rahul']['user_id']}", json={"whatsapp_number": "919876543210"})

    later = Api(client, ADMIN_A)  # "logged out, then logged in again"
    assert [r["report_id"] for r in later.get("/reports").json()] == [rid]
    row = later.results(rid)["Rahul"]
    assert row["payable_bonus"] == 30.0 and row["whatsapp_number"] == "919876543210"
    assert len(later.get(f"/users/{row['user_id']}/history").json()["history"]) == 1
