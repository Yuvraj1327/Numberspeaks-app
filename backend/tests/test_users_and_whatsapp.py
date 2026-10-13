"""User management (WhatsApp number) and the WhatsApp 'opened' record."""

import pytest

from app.services.users_service import normalize_whatsapp_number
from tests.conftest import ADMIN_A, build_pdf


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


# --- WhatsApp: sent through the server-side No1API integration ------------------
from app.services import no1api_client  # noqa: E402
from app.services.no1api_client import ProviderOutcomeUnknown, ProviderSendError, SendOutcome  # noqa: E402


@pytest.fixture()
def provider(monkeypatch):
    """A fake No1API: records calls; `behaviour` decides the outcome."""
    state = {"calls": [], "behaviour": lambda n, m: SendOutcome(provider_message_id="pm-1", status="sent")}

    def send_text(number, message):
        state["calls"].append((number, message))
        return state["behaviour"](number, message)

    monkeypatch.setattr(no1api_client, "is_available", lambda: True)
    monkeypatch.setattr(no1api_client, "send_text", send_text)
    return state


def send(a, rid, row, message="Hi Rahul, you've got ₹30 bonus."):
    return a.post(f"/reports/{rid}/results/{row['bonus_result_id']}/whatsapp-send", json={"message": message})


def numbered(a):
    rid, row = user_id(a)
    a.patch(f"/users/{row['user_id']}", json={"whatsapp_number": "919876543210"})
    return rid, row


def test_results_start_as_pending(a):
    rid, row = user_id(a)
    assert row["send_status"] == "pending"


def test_send_goes_to_the_saved_number_and_is_recorded_as_sent(a, provider, fake_db):
    rid, row = numbered(a)
    r = send(a, rid, row, message="edited by admin")
    assert r.status_code == 200, r.text
    assert r.json()["send_status"] == "sent" and r.json()["sent_at"]
    assert provider["calls"] == [("919876543210", "edited by admin")]
    after = a.results(rid)["Rahul"]
    assert after["send_status"] == "sent" and after["sent_at"] and after["send_error"] is None
    log = fake_db.tables["whatsapp_sends"]
    assert len(log) == 1 and log[0]["status"] == "sent" and log[0]["provider_message_id"] == "pm-1"


def test_a_sent_message_cannot_be_sent_twice(a, provider):
    rid, row = numbered(a)
    assert send(a, rid, row).status_code == 200
    assert send(a, rid, row).status_code == 409
    assert len(provider["calls"]) == 1


def test_failure_is_recorded_and_can_be_retried_once(a, provider, fake_db):
    rid, row = numbered(a)

    def boom(n, m):
        raise ProviderSendError("provider said no")

    provider["behaviour"] = boom
    r = send(a, rid, row)
    assert r.status_code == 200 and r.json()["send_status"] == "failed" and r.json()["send_error"] == "provider said no"
    assert a.results(rid)["Rahul"]["send_status"] == "failed"

    provider["behaviour"] = lambda n, m: SendOutcome("pm-2", status="sent")
    r2 = send(a, rid, row)
    assert r2.status_code == 200, r2.text
    assert r2.json()["send_status"] == "sent"
    assert [x["status"] for x in fake_db.tables["whatsapp_sends"]] == ["failed", "sent"]  # history kept
    assert send(a, rid, row).status_code == 409


def test_unexpected_provider_error_is_unknown_without_leaking_details(a, provider):
    rid, row = numbered(a)

    def boom(n, m):
        raise RuntimeError("secret-token-123 in url")

    provider["behaviour"] = boom
    body = send(a, rid, row).json()
    assert body["send_status"] == "unknown" and "secret" not in str(body) and "RuntimeError" in body["send_error"]


def test_a_send_already_in_progress_blocks_a_second_one(a, provider, fake_db):
    rid, row = numbered(a)
    fake_db.table("whatsapp_sends").insert(
        {"owner_id": ADMIN_A, "bonus_result_id": row["bonus_result_id"], "whatsapp_number": "1", "message_body": "x",
         "status": "sending"}
    ).execute()
    from datetime import datetime, timezone

    fake_db.tables["whatsapp_sends"][0]["created_at"] = datetime.now(timezone.utc).isoformat()  # fresh, not stale
    assert send(a, rid, row).status_code == 409
    assert provider["calls"] == []


def test_a_stale_sending_attempt_becomes_unknown_and_retry_is_allowed(a, provider, fake_db):
    rid, row = numbered(a)
    fake_db.table("whatsapp_sends").insert(
        {"owner_id": ADMIN_A, "bonus_result_id": row["bonus_result_id"], "whatsapp_number": "1", "message_body": "x",
         "status": "sending"}
    ).execute()
    fake_db.tables["whatsapp_sends"][0]["created_at"] = "2020-01-01T00:00:00+00:00"
    assert send(a, rid, row).status_code == 409  # expired -> unknown -> needs the admin's acknowledgement
    ok = a.post(f"/reports/{rid}/results/{row['bonus_result_id']}/whatsapp-send",
                json={"message": "again", "acknowledge_unknown": True})
    assert ok.json()["send_status"] == "sent"
    assert fake_db.tables["whatsapp_sends"][0]["status"] == "unknown"
    assert "unknown" in fake_db.tables["whatsapp_sends"][0]["error_message"]


def test_not_configured_provider_sends_nothing_and_creates_no_record(a, fake_db):
    rid, row = numbered(a)  # no `provider` fixture: the real stub is unavailable
    r = send(a, rid, row)
    assert r.status_code == 503
    assert fake_db.tables.get("whatsapp_sends", []) == []
    assert a.results(rid)["Rahul"]["send_status"] == "pending"


def test_no_bonus_message_for_a_user_with_nothing_payable(a, provider):
    rid, row = user_id(a, "Winner", 10000)  # carries -300, payable 0
    a.patch(f"/users/{row['user_id']}", json={"whatsapp_number": "919876543210"})
    assert send(a, rid, row).status_code == 409
    assert provider["calls"] == []


def test_cannot_send_before_the_bonus_is_calculated(a, provider):
    rid = a.upload([("Rahul", -1000)]).json()["report_id"]
    assert send(a, rid, a.results(rid)["Rahul"]).status_code == 409


def test_missing_number_or_message_is_rejected(a, provider):
    rid, row = user_id(a)  # no saved number
    assert send(a, rid, row).status_code == 422
    a.patch(f"/users/{row['user_id']}", json={"whatsapp_number": "919876543210"})
    assert send(a, rid, row, message="").status_code == 422
    assert send(a, rid, row, message="   ").status_code == 422
    assert provider["calls"] == []


def test_unknown_result_is_404(a, provider):
    rid, row = user_id(a)
    r = a.post(f"/reports/{rid}/results/00000000-0000-4000-8000-000000000999/whatsapp-send", json={"message": "x"})
    assert r.status_code == 404


def test_wa_me_opened_endpoint_is_gone(client):
    from app.main import app

    assert "whatsapp-initiated" not in " ".join(r.path for r in app.routes)


def test_every_attempt_is_saved_with_report_user_number_message_and_provider_id(a, provider, fake_db):
    rid, row = numbered(a)
    send(a, rid, row, message="the exact text")
    log = fake_db.tables["whatsapp_sends"][0]
    assert log["report_id"] == rid and log["user_id"] == row["user_id"] and log["bonus_result_id"] == row["bonus_result_id"]
    assert log["whatsapp_number"] == "919876543210" and log["message_body"] == "the exact text"
    assert log["provider_message_id"] == "pm-1" and log["status"] == "sent" and log["created_at"]


def test_an_unanswered_request_is_unknown_not_sent_and_can_be_retried_explicitly(a, provider):
    rid, row = numbered(a)

    def timeout(n, m):
        raise ProviderOutcomeUnknown()

    provider["behaviour"] = timeout
    assert send(a, rid, row).json()["send_status"] == "unknown"
    assert a.results(rid)["Rahul"]["send_status"] == "unknown"
    provider["behaviour"] = lambda n, m: SendOutcome("pm-9", status="sent")
    # A re-send after 'unknown' could be a duplicate: refused until the admin acknowledges.
    calls_before = len(provider["calls"])
    r = send(a, rid, row)
    assert r.status_code == 409 and "unknown" in r.json()["detail"].lower()
    assert len(provider["calls"]) == calls_before
    ok = a.post(f"/reports/{rid}/results/{row['bonus_result_id']}/whatsapp-send",
                json={"message": "again", "acknowledge_unknown": True})
    assert ok.json()["send_status"] == "sent"


def test_an_invalid_saved_number_is_not_sent(a, provider, fake_db):
    rid, row = numbered(a)
    next(u for u in fake_db.tables["users"])["whatsapp_number"] = "12"  # bypasses normalisation
    assert send(a, rid, row).status_code == 422
    assert provider["calls"] == []


def test_the_providers_answer_is_saved_for_an_unknown_outcome(a, provider, fake_db):
    rid, row = numbered(a)

    def odd(n, m):
        raise ProviderOutcomeUnknown("No1API answered HTTP 200: {\"status\": \"ok\"} (no message id found)")

    provider["behaviour"] = odd
    body = send(a, rid, row).json()
    assert body["send_status"] == "unknown" and "HTTP 200" in body["send_error"]
    assert "HTTP 200" in fake_db.tables["whatsapp_sends"][0]["error_message"]
    assert "HTTP 200" in a.results(rid)["Rahul"]["send_error"]


def test_a_queued_message_is_saved_as_queued_blocks_resending_and_is_not_called_sent(a, provider, fake_db):
    rid, row = numbered(a)
    provider["behaviour"] = lambda n, m: SendOutcome("q-1", status="queued", provider_status="queued")
    body = send(a, rid, row).json()
    assert body["send_status"] == "queued" and body["sent_at"] is None
    log = fake_db.tables["whatsapp_sends"][0]
    assert log["status"] == "queued" and log["provider_message_id"] == "q-1" and log["provider_status"] == "queued"
    shown = a.results(rid)["Rahul"]
    assert shown["send_status"] == "queued" and shown["sent_at"] is None
    # No silent duplicate while queued.
    assert send(a, rid, row).status_code == 409 and len(provider["calls"]) == 1


def test_test_status_reports_the_credential_source_name_only(a):
    body = a.get("/whatsapp/test-status").json()
    assert body["credential_source"] is None  # tests blank the token variables
    assert "token" not in str(body).lower().replace("credential_source", "")


@pytest.mark.parametrize("saved, expected", [
    ("7354182970", "917354182970"),          # bare 10-digit local number -> country code added
    ("07354182970", "917354182970"),         # trunk 0 dropped
    ("+917354182970", "917354182970"),       # '+' numbers are used as typed
    ("917354182970", "917354182970"),        # already has the country code
    ("+14155550123", "14155550123"),         # other countries untouched
    ("98765-43210", "919876543210"),
])
def test_to_international(saved, expected):
    from app.services.users_service import to_international

    assert to_international(saved, "91") == expected


def test_to_international_can_be_disabled():
    from app.services.users_service import to_international

    assert to_international("7354182970", "") == "7354182970"


def test_a_10_digit_saved_number_is_sent_with_the_country_code_and_not_rewritten(a, provider, fake_db):
    rid, row = user_id(a)
    a.patch(f"/users/{row['user_id']}", json={"whatsapp_number": "7354182970"})
    send(a, rid, row)
    assert provider["calls"][0][0] == "917354182970"
    assert fake_db.tables["whatsapp_sends"][0]["whatsapp_number"] == "917354182970"
    assert a.get(f"/users/{row['user_id']}").json()["whatsapp_number"] == "7354182970"


def test_a_queued_message_that_never_arrived_can_be_resent_only_after_acknowledgement(a, provider, fake_db):
    rid, row = numbered(a)
    provider["behaviour"] = lambda n, m: SendOutcome("q-1", status="queued", provider_status="queued")
    send(a, rid, row)
    assert send(a, rid, row).status_code == 409                       # no silent duplicate
    ok = a.post(f"/reports/{rid}/results/{row['bonus_result_id']}/whatsapp-send",
                json={"message": "again", "acknowledge_unknown": True})
    assert ok.status_code == 200 and ok.json()["send_status"] == "queued"
    assert [x["status"] for x in fake_db.tables["whatsapp_sends"]] == ["failed", "queued"]  # history kept
    assert len(provider["calls"]) == 2
