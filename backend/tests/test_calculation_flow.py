"""End-to-end bonus calculation through the API: loss/win, carry-forward,
recalculation, history, configurable rates, guards."""


def by_name(results):
    return {r["user_name"]: r for r in results}


def test_loss_win_zero_through_the_api(a):
    rid, r = a.run_week([("L1", -1000), ("L2", -10000), ("W", 10000), ("Z", 0)])
    assert (r["L1"]["personal_adjustment"], r["L1"]["payable_bonus"]) == (30.0, 30.0)
    assert (r["L2"]["personal_adjustment"], r["L2"]["payable_bonus"]) == (300.0, 300.0)
    assert (r["W"]["personal_adjustment"], r["W"]["payable_bonus"], r["W"]["carry_forward_balance"]) == (-300.0, 0.0, -300.0)
    assert (r["Z"]["personal_adjustment"], r["Z"]["payable_bonus"], r["Z"]["carry_forward_balance"]) == (0.0, 0.0, 0.0)
    # bonus_amount is the payable figure, never a negative adjustment
    assert r["W"]["bonus_amount"] == 0.0 and r["L2"]["bonus_amount"] == 300.0
    assert all(x["calculation_status"] == "calculated" for x in r.values())


def test_report_summary_totals(a):
    rid, _ = a.run_week([("L1", -1000), ("L2", -10000), ("W", 10000)])
    rep = a.get(f"/reports/{rid}").json()
    assert rep["status"] == "completed"
    assert rep["total_payable"] == 330.0 and rep["payable_user_count"] == 2 and rep["user_count"] == 3


def test_negative_balance_carries_forward_and_is_offset_next_period(a):
    # week 1: a 10,000 win -> -300 carried, nothing payable
    _, w1 = a.run_week([("Sam", 10000)], "w1.pdf")
    assert w1["Sam"]["payable_bonus"] == 0 and w1["Sam"]["carry_forward_balance"] == -300.0

    # week 2: a 5,000 loss -> +150, final = -300 + 150 = -150 (still nothing payable)
    _, w2 = a.run_week([("Sam", -5000)], "w2.pdf")
    s = w2["Sam"]
    assert (s["previous_balance"], s["personal_adjustment"], s["final_balance"]) == (-300.0, 150.0, -150.0)
    assert (s["payable_bonus"], s["carry_forward_balance"]) == (0.0, -150.0)

    # week 3: a 10,000 loss -> +300, final = -150 + 300 = +150 payable, carry cleared
    _, w3 = a.run_week([("Sam", -10000)], "w3.pdf")
    s = w3["Sam"]
    assert (s["previous_balance"], s["final_balance"], s["payable_bonus"], s["carry_forward_balance"]) == (-150.0, 150.0, 150.0, 0.0)

    # week 4: nothing owed from before
    _, w4 = a.run_week([("Sam", -1000)], "w4.pdf")
    assert w4["Sam"]["previous_balance"] == 0.0 and w4["Sam"]["payable_bonus"] == 30.0


def test_carry_is_per_user(a):
    a.run_week([("A", 10000), ("B", -1000)], "w1.pdf")
    _, w2 = a.run_week([("A", -1000), ("B", -1000)], "w2.pdf")
    assert w2["A"]["previous_balance"] == -300.0 and w2["A"]["final_balance"] == -270.0
    assert w2["B"]["previous_balance"] == 0.0 and w2["B"]["payable_bonus"] == 30.0


def test_a_user_missing_from_a_week_keeps_their_balance_for_the_next_one(a):
    a.run_week([("A", 10000)], "w1.pdf")
    a.run_week([("B", -1000)], "w2.pdf")          # A absent
    _, w3 = a.run_week([("A", -10000)], "w3.pdf")
    assert w3["A"]["previous_balance"] == -300.0 and w3["A"]["final_balance"] == 0.0


def test_recalculating_a_report_is_idempotent_and_adds_history(a):
    _, w1 = a.run_week([("Sam", 10000)], "w1.pdf")
    rid2, w2 = a.run_week([("Sam", -5000)], "w2.pdf")
    first = w2["Sam"]

    again = a.calculate(rid2)  # recalculating the latest report is allowed
    assert again.status_code == 200, again.text
    second = by_name(again.json()["results"])["Sam"]
    for key in ("previous_balance", "personal_adjustment", "final_balance", "payable_bonus", "carry_forward_balance"):
        assert second[key] == first[key]  # not compounded

    hist = a.get(f"/users/{first['user_id']}/history").json()["history"]
    assert len(hist) == 3  # w1 + w2 + the recalculation of w2
    assert hist[0]["calculated_at"] >= hist[-1]["calculated_at"]  # newest first


def test_an_older_report_cannot_be_changed_once_a_newer_one_is_calculated(a):
    rid1, w1 = a.run_week([("Sam", 10000)], "w1.pdf")
    a.run_week([("Sam", -5000)], "w2.pdf")
    row = w1["Sam"]["bonus_result_id"]
    assert a.patch(f"/reports/{rid1}/rows/{row}", json={"profit_loss": 1}).status_code == 409
    assert a.post(f"/reports/{rid1}/validate").status_code == 409
    assert a.post(f"/reports/{rid1}/referrals", json={"referrer_user_id": "x", "referred_user_id": "y"}).status_code == 409
    # and the later report's numbers were not disturbed
    assert a.get(f"/reports/{rid1}").json()["status"] == "completed"


def test_personal_and_referral_rates_are_configurable(a):
    assert a.get("/settings").json()["personal_rate"] == 0.03
    assert a.get("/settings").json()["referral_rate"] == 0.10
    put = a.put("/settings", json={"personal_rate": 0.05})
    assert put.status_code == 200 and put.json()["personal_rate"] == 0.05 and put.json()["referral_rate"] == 0.10

    _, r = a.run_week([("L", -1000), ("W", 1000)])
    assert r["L"]["personal_adjustment"] == 50.0 and r["L"]["personal_rate_used"] == 0.05
    assert r["W"]["personal_adjustment"] == -50.0


def test_settings_validation(a):
    assert a.put("/settings", json={"personal_rate": 3}).status_code == 422
    assert a.put("/settings", json={"referral_rate": -0.1}).status_code == 422
    assert a.get("/settings").json()["personal_rate"] == 0.03


def test_changing_the_rate_does_not_rewrite_history(a):
    rid, r = a.run_week([("L", -1000)], "w1.pdf")
    a.put("/settings", json={"personal_rate": 0.10})
    old = a.results(rid)["L"]
    assert old["personal_adjustment"] == 30.0 and old["personal_rate_used"] == 0.03


def test_user_total_and_latest_carry_in_profile(a):
    _, r = a.run_week([("Sam", 10000)])
    uid = r["Sam"]["user_id"]
    prof = a.get(f"/users/{uid}").json()
    assert prof["carry_forward_balance"] == -300.0 and prof["name"] == "Sam"
