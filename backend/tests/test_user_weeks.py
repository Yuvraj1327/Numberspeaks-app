"""Week-by-week bonus ledger per user: dates, breakdown, carry-forward, no double counting, isolation."""

from tests.test_weeks_ledger_backup import W1, W2, up, week

W3 = {"period_start": "2026-10-26", "period_end": "2026-11-01"}


def uid_of(a, rid, name="Amy"):
    return a.results(rid)[name]["user_id"]


def test_weeks_listed_newest_first_with_dates_and_breakdown(a):
    r1 = week(a, [("Amy", 10000)], W1)      # win 10,000 -> -300 carried
    r2 = week(a, [("Amy", -10000)], W2)     # +300, previous -300 -> final 0
    r3 = week(a, [("Amy", -2000)], W3)      # +60 payable
    uid = uid_of(a, r1)
    data = a.get(f"/users/{uid}/weeks").json()
    weeks = data["weeks"]
    assert [w["report_id"] for w in weeks] == [r3, r2, r1]
    assert [w["is_current"] for w in weeks] == [True, False, False]
    assert weeks[0]["week_label"] == "26 Oct - 1 Nov 2026"
    assert weeks[1]["week_label"] == "12-18 Oct 2026"
    assert weeks[2]["period_start"] == "2026-10-05" and weeks[2]["period_end"] == "2026-10-11"
    w1, w2, w3 = weeks[2], weeks[1], weeks[0]
    assert (w1["profit_loss"], w1["personal_adjustment"], w1["previous_balance"]) == (10000.0, -300.0, 0.0)
    assert (w1["payable_bonus"], w1["carry_forward_balance"]) == (0.0, -300.0)
    assert (w2["previous_balance"], w2["personal_adjustment"], w2["final_balance"]) == (-300.0, 300.0, 0.0)
    assert (w3["personal_adjustment"], w3["payable_bonus"], w3["carry_forward_balance"]) == (60.0, 60.0, 0.0)
    assert w3["send_status"] == "pending"


def test_recalculation_does_not_duplicate_a_week(a):
    r1 = week(a, [("Amy", -1000)], W1)
    a.post(f"/reports/{r1}/validate")
    a.post(f"/reports/{r1}/calculate-bonus")
    uid = uid_of(a, r1)
    assert len(a.get(f"/users/{uid}/weeks").json()["weeks"]) == 1
    # the audit trail still keeps every run, now carrying the week's dates
    hist = a.get(f"/users/{uid}/history").json()["history"]
    assert len(hist) >= 2 and hist[0]["period_start"] == "2026-10-05"


def test_uncalculated_week_not_listed_and_other_admin_gets_404(a, b):
    r1 = week(a, [("Amy", -1000)], W1)
    uid = uid_of(a, r1)
    assert up(a, [("Amy", -500)], W2).status_code == 200      # uploaded, not calculated
    assert len(a.get(f"/users/{uid}/weeks").json()["weeks"]) == 1
    assert b.get(f"/users/{uid}/weeks").status_code == 404
