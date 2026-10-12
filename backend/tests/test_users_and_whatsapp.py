"""User management (WhatsApp number) and the WhatsApp 'opened' record."""

import pytest

from app.services.users_service import normalize_whatsapp_number
from tests.conftest import build_pdf


# --- number normalisation ------------------------------------------------------
@pytest.mark.parametrize(
    "raw, expected",
    [
        ("919876543210", "919876543210"),
        ("+91 98765-43210", "+919876543210"),
        ("(022) 2345 6789", "02223456789"),
        ("  ", None),
        ("", None),
        (None, None),
    ],
)
def test_normalize_whatsapp_number(raw, expected):
    assert normalize_whatsapp_number(raw) == expected


@pytest.mark.parametrize("bad", ["abc", "12345", "+", "98765x43210", "1" * 16, "91+9876543210"])
def test_normalize_rejects_bad_numbers(bad):
    from fastapi import HTTPException

    with pytest.raises(HTTPException) as exc:
        normalize_whatsapp_number(bad)
    assert exc.value.status_code == 422


# --- manually entered numbers are saved permanently -------------------------------
def user_id(a, name="Rahul", pl=-1000):
    rid, res = a.run_week([(name, pl)])
    return rid, res[name]


def test_edit_save_and_clear_whatsapp_number(a):
    rid, row = user_id(a)
    uid = row["user_id"]
    assert row["whatsapp_number"] is None

    r = a.patch(f"/users/{uid}", json={"whatsapp_number": "+91 98765 43210"})
    assert r.status_code == 200, r.text
    assert r.json()["whatsapp_number"] == "+919876543210"

    # persisted: visible from the user, from the results table and from a fresh read
    assert a.get(f"/users/{uid}").json()["whatsapp_number"] == "+919876543210"
    assert a.results(rid)["Rahul"]["whatsapp_number"] == "+919876543210"
    assert a.get("/users", params={"q": "rahu"}).json()[0]["whatsapp_number"] == "+919876543210"

    # edit it
    assert a.patch(f"/users/{uid}", json={"whatsapp_number": "919000000001"}).json()["whatsapp_number"] == "919000000001"
    # clear it
    assert a.patch(f"/users/{uid}", json={"whatsapp_number": ""}).json()["whatsapp_number"] is None
    assert a.get(f"/users/{uid}").json()["whatsapp_number"] is None


def test_invalid_number_is_rejected_and_old_value_kept(a):
    _, row = user_id(a)
    uid = row["user_id"]
    a.patch(f"/users/{uid}", json={"whatsapp_number": "919876543210"})
    assert a.patch(f"/users/{uid}", json={"whatsapp_number": "not a number"}).status_code == 422
    assert a.get(f"/users/{uid}").json()["whatsapp_number"] == "919876543210"


def test_number_survives_a_later_weekly_upload(a):
    _, row = user_id(a)
    a.patch(f"/users/{row['user_id']}", json={"whatsapp_number": "919876543210"})
    rid2, res2 = a.run_week([("Rahul", -2000)], "w2.pdf")
    assert res2["Rahul"]["user_id"] == row["user_id"]            # same person, not a duplicate user
    assert res2["Rahul"]["whatsapp_number"] == "919876543210"    # not wiped by the new report
    assert len(a.get("/users").json()) == 1


def test_unknown_or_malformed_user_is_404(a):
    assert a.patch("/users/00000000-0000-4000-8000-000000000999", json={"whatsapp_number": "919876543210"}).status_code == 404
    assert a.patch("/users/nope", json={"whatsapp_number": "919876543210"}).status_code == 404
    assert a.get("/users/nope").status_code == 404
    assert a.get("/users/nope/history").status_code == 404


def test_user_search(a):
    a.run_week([("Rahul01", -1000), ("Rahul02", -1000), ("Priya", -1000)])
    names = {u["name"] for u in a.get("/users", params={"q": "rahul"}).json()}
    assert names == {"Rahul01", "Rahul02"}
    assert len(a.get("/users").json()) == 3


def test_history_lists_each_calculation_with_its_breakdown(a):
    _, w1 = a.run_week([("Sam", 10000)], "w1.pdf")
    a.run_week([("Sam", -5000)], "w2.pdf")
    h = a.get(f"/users/{w1['Sam']['user_id']}/history").json()
    assert h["user"]["name"] == "Sam" and len(h["history"]) == 2
    newest, oldest = h["history"][0], h["history"][1]
    assert oldest["personal_adjustment"] == -300.0 and oldest["carry_forward_balance"] == -300.0
    assert newest["previous_balance"] == -300.0 and newest["final_balance"] == -150.0 and newest["payable_bonus"] == 0.0
    assert {newest["report_file_name"], oldest["report_file_name"]} == {"w1.pdf", "w2.pdf"}


# --- WhatsApp: only an 'opened' record, never 'sent' -------------------------------
def initiate(a, rid, row, number="919876543210", message="Hi Rahul, you've got ₹30 bonus. Please enjoy your game!"):
    return a.post(
        f"/reports/{rid}/results/{row['bonus_result_id']}/whatsapp-initiated",
        json={"whatsapp_number": number, "message": message},
    )


def test_record_that_whatsapp_was_opened(a):
    rid, row = user_id(a)
    assert row["whatsapp_status"] == "not_sent"
    r = initiate(a, rid, row)
    assert r.status_code == 200, r.text
    assert r.json()["whatsapp_status"] == "initiated" and r.json()["whatsapp_initiated_count"] == 1

    after = a.results(rid)["Rahul"]
    assert after["whatsapp_initiated_count"] == 1 and after["whatsapp_initiated_at"]
    assert after["whatsapp_status"] == "initiated"  # NEVER 'sent' / 'delivered'

    assert initiate(a, rid, row).json()["whatsapp_initiated_count"] == 2


def test_the_message_and_number_that_were_opened_are_logged(a, fake_db):
    rid, row = user_id(a)
    initiate(a, rid, row, number="+91 98765 43210", message="edited by admin")
    log = fake_db.tables["whatsapp_initiations"]
    assert len(log) == 1 and log[0]["message_body"] == "edited by admin" and log[0]["whatsapp_number"] == "+919876543210"


def test_no_bonus_message_for_a_user_with_nothing_payable(a):
    rid, row = user_id(a, "Winner", 10000)  # carries -300, payable 0
    assert initiate(a, rid, row).status_code == 409
    assert a.results(rid)["Winner"]["whatsapp_status"] == "not_sent"


def test_cannot_record_before_the_bonus_is_calculated(a):
    rid = a.upload([("Rahul", -1000)]).json()["report_id"]
    row = a.results(rid)["Rahul"]
    assert initiate(a, rid, row).status_code == 409


def test_missing_number_or_message_is_rejected(a):
    rid, row = user_id(a)
    assert initiate(a, rid, row, number="").status_code == 422
    assert initiate(a, rid, row, number="abc").status_code == 422
    assert initiate(a, rid, row, message="").status_code == 422
    assert a.results(rid)["Rahul"]["whatsapp_initiated_count"] == 0


def test_unknown_result_is_404(a):
    rid, row = user_id(a)
    r = a.post(f"/reports/{rid}/results/00000000-0000-4000-8000-000000000999/whatsapp-initiated",
               json={"whatsapp_number": "919876543210", "message": "x"})
    assert r.status_code == 404


def test_there_is_no_server_side_send_endpoint(client):
    from app.main import app

    paths = " ".join(r.path for r in app.routes)
    assert "send-whatsapp" not in paths and "/whatsapp/send" not in paths
