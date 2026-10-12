"""Weekly periods, duplicate prevention, ledger/referrers, user edit, backup/restore, CSV, isolation."""

import json

from tests.conftest import build_pdf

W1 = {"period_start": "2026-10-05", "period_end": "2026-10-11"}
W2 = {"period_start": "2026-10-12", "period_end": "2026-10-18"}


def up(a, rows, period, name="w.pdf", **extra):
    pdf = build_pdf(rows)
    return a.post("/reports/upload", files={"file": (name, pdf, "application/pdf")}, data={**period, **extra})


def week(a, rows, period):
    r = up(a, rows, period)
    assert r.status_code == 200, r.text
    rid = r.json()["report_id"]
    assert a.calculate(rid).json()["status"] == "completed"
    return rid


def test_period_saved_and_listed_latest_first(a):
    r1 = week(a, [("Amy", -1000)], W1)
    r2 = week(a, [("Amy", -1000)], W2)
    hist = a.get("/reports").json()
    assert [h["report_id"] for h in hist] == [r2, r1]
    assert hist[1]["period_start"] == "2026-10-05" and hist[1]["period_end"] == "2026-10-11"


def test_duplicate_period_rejected_and_overlap_rejected(a):
    week(a, [("Amy", -1000)], W1)
    d = up(a, [("Amy", -1)], W1)
    assert d.status_code == 409 and "already exists" in d.json()["detail"]
    o = up(a, [("Amy", -1)], {"period_start": "2026-10-08", "period_end": "2026-10-14"})
    assert o.status_code == 409 and "overlaps" in o.json()["detail"]
    assert len(a.get("/reports").json()) == 1


def test_bad_period_values(a):
    assert up(a, [("Amy", -1)], {"period_start": "2026-10-11", "period_end": "2026-10-05"}).status_code == 422
    assert up(a, [("Amy", -1)], {"period_start": "2026-10-05"}).status_code == 422
    assert up(a, [("Amy", -1)], {"period_start": "nope", "period_end": "x"}).status_code == 422


def test_carry_forward_follows_period_not_upload_order(a):
    # Import the LATER week first; calculate the earlier week first. Week 2 must
    # carry week 1's balance even though it was uploaded before it.
    r2 = up(a, [("Amy", -10000)], W2).json()["report_id"]
    r1 = week(a, [("Amy", 20000)], W1)                     # win -> -600 carried
    assert a.calculate(r2).json()["status"] == "completed"
    amy = a.results(r2)["Amy"]
    assert amy["previous_balance"] == -600.0 and amy["final_balance"] == -300.0
    # the earlier week is now locked: a newer week depends on its carry-forward
    assert a.post(f"/reports/{r1}/validate").status_code == 409


def test_carry_forward_in_order(a):
    r1 = week(a, [("Amy", 10000)], W1)           # -300
    r2 = week(a, [("Amy", -10000)], W2)          # +300 personal, previous -300
    amy = a.results(r2)["Amy"]
    assert amy["previous_balance"] == -300.0 and amy["final_balance"] == 0.0
    # Recalculating week 2 gives the same numbers (carried exactly once)
    a.post(f"/reports/{r2}/validate")
    again = a.post(f"/reports/{r2}/calculate-bonus").json()["results"][0]
    assert again["previous_balance"] == -300.0 and again["final_balance"] == 0.0
    assert a.results(r1)["Amy"]["carry_forward_balance"] == -300.0


def test_replace_requires_flag_keeps_history_and_referrals(a):
    r1 = week(a, [("Boss", 0), ("R1", -1000)], W1)
    u = {n: v["user_id"] for n, v in a.results(r1).items()}
    a.post(f"/reports/{r1}/referrals", json={"referrer_user_id": u["Boss"], "referred_user_id": u["R1"]})
    assert up(a, [("Boss", 0), ("R1", -2000)], W1).status_code == 409
    rep = up(a, [("Boss", 0), ("R1", -2000)], W1, replace="true")
    assert rep.status_code == 200, rep.text
    new = rep.json()
    assert new["replaced_report_id"] == r1 and new["report_id"] != r1
    assert a.get(f"/reports/{r1}").status_code == 404
    reports = a.get("/reports").json()
    assert len(reports) == 1 and reports[0]["period_start"] == "2026-10-05"
    assert a.results(new["report_id"])["R1"]["profit_loss"] == -2000.0
    assert len(a.get(f"/reports/{new['report_id']}/referrals").json()) == 1  # entry survived


def test_replace_blocked_when_later_week_calculated(a):
    week(a, [("Amy", 10000)], W1)
    week(a, [("Amy", 10000)], W2)
    assert up(a, [("Amy", 1)], W1, replace="true").status_code == 409


def test_replace_with_bad_pdf_keeps_old_week(a, client):
    r1 = week(a, [("Amy", 10000)], W1)
    bad = a.post("/reports/upload", files={"file": ("x.pdf", b"%PDF-garbage", "application/pdf")}, data={**W1, "replace": "true"})
    assert bad.status_code >= 400
    assert a.get(f"/reports/{r1}").status_code == 200


def test_ledger_manual_entry_edit_delete_and_no_duplicates(a):
    r1 = week(a, [("Boss", 0), ("R1", -1000)], W1)
    u = {n: v["user_id"] for n, v in a.results(r1).items()}
    body = {"report_id": r1, "referrer_user_id": u["Boss"], "referred_user_id": u["R1"], "amount": -5000, "rate": 0.2}
    e = a.post("/referral-ledger", json=body)
    assert e.status_code == 201, e.text
    assert e.json()["amount_source"] == "manual" and e.json()["period_start"] == "2026-10-05"
    assert a.post("/referral-ledger", json=body).status_code == 409   # no double counting
    res = a.post(f"/reports/{r1}/validate")
    calc = a.post(f"/reports/{r1}/calculate-bonus").json()
    boss = {r["user_name"]: r for r in calc["results"]}["Boss"]
    assert boss["referral_adjustment"] == 1000.0                     # 20% of manual 5000 loss
    assert boss["referred_count"] == 1
    r1u = {r["user_name"]: r for r in calc["results"]}["R1"]
    assert r1u["referrer_name"] == "Boss"
    eid = e.json()["entry_id"]
    p = a.patch(f"/referral-ledger/{eid}", json={"clear_amount": True, "rate": 0.1})
    assert p.status_code == 200 and p.json()["amount_source"] == "report"
    led = a.get("/referral-ledger").json()
    assert len(led) == 1
    assert a.delete(f"/referral-ledger/{eid}").status_code == 204
    assert a.get("/referral-ledger").json() == []


def test_manual_win_gives_negative_adjustment(a):
    r1 = week(a, [("Boss", 0), ("R1", 0)], W1)
    u = {n: v["user_id"] for n, v in a.results(r1).items()}
    a.post("/referral-ledger", json={"report_id": r1, "referrer_user_id": u["Boss"], "referred_user_id": u["R1"], "amount": 3000})
    a.post(f"/reports/{r1}/validate")
    boss = {r["user_name"]: r for r in a.post(f"/reports/{r1}/calculate-bonus").json()["results"]}["Boss"]
    assert boss["referral_adjustment"] == -300.0


def test_referrers_crud_default_rate_and_totals(a):
    r1 = week(a, [("Boss", 0), ("R1", -1000)], W1)
    u = {n: v["user_id"] for n, v in a.results(r1).items()}
    ref = a.post("/referrers", json={"user_id": u["Boss"], "display_name": "The Boss", "default_rate": 0.05})
    assert ref.status_code == 201, ref.text
    assert a.post("/referrers", json={"user_id": u["Boss"]}).status_code == 409
    # entry without a rate uses the referrer's own default
    e = a.post(f"/reports/{r1}/referrals", json={"referrer_user_id": u["Boss"], "referred_user_id": u["R1"]}).json()
    assert e["rate"] == 0.05
    a.post(f"/reports/{r1}/validate"); a.calculate  # noqa: B018
    a.post(f"/reports/{r1}/calculate-bonus")
    rid = ref.json()["referrer_id"]
    p = a.patch(f"/referrers/{rid}", json={"notes": "vip", "is_active": False}).json()
    assert p["notes"] == "vip" and p["is_active"] is False and p["referred_count"] == 1 and p["total_adjustment"] == 50.0
    assert a.delete(f"/referrers/{rid}").status_code == 204
    assert a.get("/referrers").json() == []


def test_user_edit_name_level_whatsapp(a):
    r1 = week(a, [("Amy", 0), ("Bob", 0)], W1)
    uid = a.results(r1)["Amy"]["user_id"]
    p = a.patch(f"/users/{uid}", json={"name": "Amy2", "level": "Pro", "whatsapp_number": "+91 98765 43210"})
    assert p.status_code == 200 and p.json()["name"] == "Amy2" and p.json()["whatsapp_number"] == "+919876543210"
    assert a.patch(f"/users/{uid}", json={"name": "Bob"}).status_code == 409
    assert a.patch(f"/users/{uid}", json={"whatsapp_number": "abc"}).status_code == 422
    assert a.get(f"/users/{uid}").json()["whatsapp_number"] == "+919876543210"   # persisted


def test_whatsapp_template_saved_permanently(a):
    t = "Hi {name} ({user_id}) week {week}: {bonus} = {personal_bonus}+{referral_bonus}+{carried_balance}"
    assert a.put("/settings", json={"whatsapp_template": t}).json()["whatsapp_template"] == t
    assert a.get("/settings").json()["whatsapp_template"] == t
    assert a.put("/settings", json={"whatsapp_template": "  "}).json()["whatsapp_template"] is None


def test_csv_exports_and_formula_neutralised(a):
    r1 = week(a, [("=cmd", -1000), ("R1", -1000)], W1)
    u = {n: v["user_id"] for n, v in a.results(r1).items()}
    a.post("/referral-ledger", json={"report_id": r1, "referrer_user_id": u["R1"], "referred_user_id": u["=cmd"]})
    users = a.get("/export/users.csv")
    assert users.status_code == 200 and "'=cmd" in users.text and "text/csv" in users.headers["content-type"]
    assert "referrer_id" in a.get("/export/referrals.csv").text
    wk = a.get(f"/reports/{r1}/export.csv").text
    assert "payable_bonus" in wk and "30.0" in wk


def test_backup_restore_roundtrip(a, fake_db):
    r1 = week(a, [("Boss", 0), ("R1", -1000)], W1)
    u = {n: v["user_id"] for n, v in a.results(r1).items()}
    a.post("/referral-ledger", json={"report_id": r1, "referrer_user_id": u["Boss"], "referred_user_id": u["R1"]})
    a.put("/settings", json={"whatsapp_template": "Hi {name}"})
    backup = a.get("/backup").json()
    assert backup["version"] == 1 and len(backup["tables"]["users"]) == 2
    # simulate data loss, then restore
    for t in ("referral_entries", "bonus_results", "reports", "users"):
        fake_db.tables[t] = []
    r = a.post("/restore", json=backup)
    assert r.status_code == 200, r.text
    assert r.json()["restored"]["users"] == 2 and r.json()["restored"]["bonus_results"] == 2
    assert a.results(r1)["R1"]["profit_loss"] == -1000.0
    assert len(a.get("/referral-ledger").json()) == 1
    assert a.get("/settings").json()["whatsapp_template"] == "Hi {name}"
    # restoring again is idempotent
    assert a.post("/restore", json=backup).status_code == 200
    assert len(a.get("/users").json()) == 2


def test_restore_rejects_garbage_and_other_accounts_ids(a, b):
    r1 = week(a, [("Amy", -1000)], W1)
    backup = a.get("/backup").json()
    assert b.post("/restore", json=backup).status_code == 409      # ids belong to A
    assert b.get("/users").json() == []                            # and nothing leaked/written
    assert b.post("/restore", json={"foo": 1}).status_code == 422
    bad = {"app": "numberspeaks", "version": 1, "tables": {"users": [{"id": "not-a-uuid"}]}}
    assert b.post("/restore", json=bad).status_code == 422


def test_isolation_of_new_endpoints(a, b):
    r1 = week(a, [("Boss", 0), ("R1", -1000)], W1)
    u = {n: v["user_id"] for n, v in a.results(r1).items()}
    e = a.post("/referral-ledger", json={"report_id": r1, "referrer_user_id": u["Boss"], "referred_user_id": u["R1"]}).json()
    ref = a.post("/referrers", json={"user_id": u["Boss"]}).json()
    assert b.get("/referral-ledger").json() == [] and b.get("/referrers").json() == []
    assert b.patch(f"/referral-ledger/{e['entry_id']}", json={"rate": 0.5}).status_code == 404
    assert b.delete(f"/referral-ledger/{e['entry_id']}").status_code == 404
    assert b.patch(f"/referrers/{ref['referrer_id']}", json={"notes": "x"}).status_code == 404
    assert b.post("/referral-ledger", json={"report_id": r1, "referrer_user_id": u["Boss"], "referred_user_id": u["R1"]}).status_code == 404
    assert b.get(f"/reports/{r1}/export.csv").status_code == 404
    assert b.patch(f"/users/{u['Boss']}", json={"name": "hack"}).status_code == 404
    assert "Boss" not in b.get("/export/users.csv").text
    # same week can be imported by B independently of A's
    assert up(b, [("Amy", -1)], W1).status_code == 200
