"""Bulk WhatsApp sending: confirmation, test-number gate, skipping, rate limit, duplicates, isolation."""

import pytest

from app.services import no1api_client, whatsapp_service
from app.services.no1api_client import ProviderSendError, SendOutcome
from tests.conftest import ADMIN_A


@pytest.fixture()
def provider(monkeypatch):
    state = {"calls": [], "behaviour": lambda n, m: SendOutcome(provider_message_id="pm")}
    sleeps = []

    def send_text(number, message):
        state["calls"].append((number, message))
        return state["behaviour"](number, message)

    monkeypatch.setattr(no1api_client, "is_available", lambda: True)
    monkeypatch.setattr(no1api_client, "send_text", send_text)
    monkeypatch.setattr(whatsapp_service, "_sleep", sleeps.append)
    state["sleeps"] = sleeps
    return state


@pytest.fixture()
def week(a):
    """Calculated report: Amy, Bo payable with numbers; Cy payable without; Di invalid number; Ed no bonus."""
    rid, res = a.run_week([("Amy", -1000), ("Bo", -2000), ("Cy", -3000), ("Di", -4000), ("Ed", 5000)])
    for name, number in [("Amy", "919000000001"), ("Bo", "919000000002"), ("Ed", "919000000005")]:
        a.patch(f"/users/{res[name]['user_id']}", json={"whatsapp_number": number})
    return rid, res


def items(res, *names):
    return [{"bonus_result_id": res[n]["bonus_result_id"], "message": f"hi {n}"} for n in names]


def bulk(a, rid, its, confirmed=True):
    return a.post(f"/reports/{rid}/whatsapp-bulk", json={"items": its, "confirmed": confirmed})


def final(a, rid, response):
    """The POST answers immediately (before the background run); progress is read afterwards."""
    assert response.status_code == 200, response.text
    return a.get(f"/reports/{rid}/whatsapp-bulk/{response.json()['batch_id']}").json()


def pass_test_gate(a):
    r = a.post("/whatsapp/test-send", json={"whatsapp_number": "+91 90000 99999", "message": "test", "authorized": True})
    assert r.status_code == 200 and r.json()["status"] == "sent", r.text


def test_bulk_is_refused_until_a_test_message_was_accepted(a, week, provider):
    rid, res = week
    assert a.get("/whatsapp/test-status").json()["tested"] is False
    r = bulk(a, rid, items(res, "Amy"))
    assert r.status_code == 409 and "test" in r.json()["detail"].lower()
    assert provider["calls"] == []


def test_a_failed_test_does_not_open_the_gate(a, week, provider):
    rid, res = week
    provider["behaviour"] = lambda n, m: (_ for _ in ()).throw(ProviderSendError("nope"))
    r = a.post("/whatsapp/test-send", json={"whatsapp_number": "919000099999", "message": "t", "authorized": True})
    assert r.json()["status"] == "failed"
    assert a.get("/whatsapp/test-status").json()["tested"] is False


def test_test_send_needs_authorization_and_a_valid_number(a, provider):
    assert a.post("/whatsapp/test-send", json={"whatsapp_number": "919000099999", "message": "t", "authorized": False}).status_code == 422
    assert a.post("/whatsapp/test-send", json={"whatsapp_number": "12", "message": "t", "authorized": True}).status_code == 422
    assert provider["calls"] == []


def test_bulk_requires_explicit_confirmation(a, week, provider):
    rid, res = week
    pass_test_gate(a)
    provider["calls"].clear()
    assert bulk(a, rid, items(res, "Amy"), confirmed=False).status_code == 422
    assert provider["calls"] == []


def test_bulk_sends_eligible_skips_the_rest_and_reports_progress(a, week, provider, fake_db):
    rid, res = week
    pass_test_gate(a)
    provider["calls"].clear()
    r = bulk(a, rid, items(res, "Amy", "Bo", "Cy", "Ed"))
    assert r.status_code == 200, r.text
    batch = r.json()["batch_id"]
    assert [c[1] for c in provider["calls"]] == ["hi Amy", "hi Bo"]
    # rate limiting: one pause between the two messages
    assert len(provider["sleeps"]) == 1

    p = a.get(f"/reports/{rid}/whatsapp-bulk/{batch}").json()
    assert p["status"] == "completed" and p["queued"] == 2 and p["sent"] == 2 and p["failed"] == 0 and p["pending"] == 0
    reasons = {s["user_name"]: s["reason"] for s in p["skipped"]}
    assert "number" in reasons["Cy"].lower() and "payable" in reasons["Ed"].lower() or "bonus" in reasons["Ed"].lower()
    assert p["total_selected"] == 4
    assert a.results(rid)["Amy"]["send_status"] == "sent" and a.results(rid)["Cy"]["send_status"] == "pending"
    log = [r for r in fake_db.tables["whatsapp_sends"] if r["batch_id"] == batch]
    assert len(log) == 2 and all(r["report_id"] == rid and r["provider_message_id"] == "pm" for r in log)


def test_bulk_records_failures_and_continues(a, week, provider):
    rid, res = week
    pass_test_gate(a)

    def behaviour(n, m):
        if m == "hi Amy":
            raise ProviderSendError("bad number")
        return SendOutcome("pm")

    provider["behaviour"] = behaviour
    p = final(a, rid, bulk(a, rid, items(res, "Amy", "Bo")))
    assert p["sent"] == 1 and p["failed"] == 1
    assert p["items"] == [{"bonus_result_id": res["Amy"]["bonus_result_id"], "user_name": "Amy", "send_status": "failed", "send_error": "bad number"}]
    # Failed ones can be retried explicitly; the sent one is skipped, never re-sent.
    provider["behaviour"] = lambda n, m: SendOutcome("pm2")
    provider["calls"].clear()
    p2 = final(a, rid, bulk(a, rid, items(res, "Amy", "Bo")))
    assert [c[1] for c in provider["calls"]] == ["hi Amy"]
    assert p2["sent"] == 1 and [s["reason"] for s in p2["skipped"]] == ["Already sent."]


def test_bulk_never_resends_what_was_already_sent(a, week, provider):
    rid, res = week
    pass_test_gate(a)
    bulk(a, rid, items(res, "Amy"))
    provider["calls"].clear()
    p = final(a, rid, bulk(a, rid, items(res, "Amy")))
    assert provider["calls"] == [] and p["queued"] == 0 and p["status"] == "completed"


def test_only_one_bulk_run_at_a_time(a, week, provider, fake_db):
    rid, res = week
    pass_test_gate(a)
    from datetime import datetime, timezone

    fake_db.table("whatsapp_batches").insert(
        {"owner_id": ADMIN_A, "report_id": rid, "status": "running", "total_queued": 1,
         "updated_at": datetime.now(timezone.utc).isoformat()}
    ).execute()
    assert bulk(a, rid, items(res, "Amy")).status_code == 409


def test_bulk_not_configured_sends_nothing(a, week, fake_db):
    rid, res = week  # real stub provider
    assert bulk(a, rid, items(res, "Amy")).status_code == 503
    assert fake_db.tables.get("whatsapp_sends", []) == []


def test_other_admin_cannot_bulk_send_or_read_progress(a, b, week, provider):
    rid, res = week
    pass_test_gate(a)
    pass_test_gate(b)
    assert bulk(b, rid, items(res, "Amy")).status_code == 404
    batch = bulk(a, rid, items(res, "Amy")).json()["batch_id"]
    assert b.get(f"/reports/{rid}/whatsapp-bulk/{batch}").status_code == 404
    assert a.get("/whatsapp/test-status").json()["tested"] is True


def test_unknown_batch_is_404(a, week, provider):
    rid, _ = week
    assert a.get(f"/reports/{rid}/whatsapp-bulk/not-a-uuid").status_code == 404
