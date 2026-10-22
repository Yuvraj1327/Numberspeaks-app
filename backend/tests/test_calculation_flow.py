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

    # reports are CUMULATIVE: week 2 total 5,000 = a 5,000 loss this week (5,000 - 10,000)
    # week 2: a 5,000 loss -> +150, final = -300 + 150 = -150 (still nothing payable)
    _, w2 = a.run_week([("Sam", 5000)], "w2.pdf")
    s = w2["Sam"]
    assert (s["previous_balance"], s["personal_adjustment"], s["final_balance"]) == (-300.0, 150.0, -150.0)
    assert (s["payable_bonus"], s["carry_forward_balance"]) == (0.0, -150.0)

    # week 3: a 10,000 loss -> +300, final = -150 + 300 = +150 payable, carry cleared
    _, w3 = a.run_week([("Sam", -5000)], "w3.pdf")
    s = w3["Sam"]
    assert (s["previous_balance"], s["final_balance"], s["payable_bonus"], s["carry_forward_balance"]) == (-150.0, 150.0, 150.0, 0.0)

    # week 4: nothing owed from before
    _, w4 = a.run_week([("Sam", -6000)], "w4.pdf")
    assert w4["Sam"]["previous_balance"] == 0.0 and w4["Sam"]["payable_bonus"] == 30.0


def test_carry_is_per_user(a):
    a.run_week([("A", 10000), ("B", -1000)], "w1.pdf")
    _, w2 = a.run_week([("A", 9000), ("B", -2000)], "w2.pdf")
    assert w2["A"]["previous_balance"] == -300.0 and w2["A"]["final_balance"] == -270.0
    assert w2["B"]["previous_balance"] == 0.0 and w2["B"]["payable_bonus"] == 30.0


def test_a_user_missing_from_a_week_keeps_their_balance_for_the_next_one(a):
    a.run_week([("A", 10000)], "w1.pdf")
    a.run_week([("B", -1000)], "w2.pdf")          # A absent
    _, w3 = a.run_week([("A", 0)], "w3.pdf")
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


# --- weekly difference: reports are cumulative -------------------------------------


def test_first_report_uses_the_whole_total_as_the_week(a):
    _, w1 = a.run_week([("Sam", -1000)], "w1.pdf")
    s = w1["Sam"]
    assert (s["previous_report_total"], s["current_report_total"]) == (0.0, -1000.0)
    assert (s["weekly_change"], s["bonus_basis"], s["personal_adjustment"]) == (-1000.0, -1000.0, 30.0)


def test_loss_grows_bonus_only_on_the_additional_loss(a):
    a.run_week([("Sam", -90)], "w1.pdf")
    _, w2 = a.run_week([("Sam", -100)], "w2.pdf")     # 100 now vs 90 before -> 10 more lost
    s = w2["Sam"]
    assert (s["previous_report_total"], s["current_report_total"], s["weekly_change"]) == (-90.0, -100.0, -10.0)
    assert s["bonus_basis"] == -10.0 and s["personal_adjustment"] == 0.3  # 3% of 10, not of 100


def test_win_grows_adjustment_only_on_the_additional_win(a):
    a.run_week([("Sam", 150)], "w1.pdf")
    _, w2 = a.run_week([("Sam", 200)], "w2.pdf")      # 50 more won
    s = w2["Sam"]
    assert s["weekly_change"] == 50.0 and s["personal_adjustment"] == -1.5


def test_a_win_that_shrinks_the_cumulative_loss_counts_as_a_weekly_win(a):
    a.run_week([("Sam", -1000)], "w1.pdf")
    _, w2 = a.run_week([("Sam", -400)], "w2.pdf")     # cumulative loss fell: +600 this week
    s = w2["Sam"]
    assert s["weekly_change"] == 600.0 and s["personal_adjustment"] == -18.0
    assert s["previous_balance"] == 0.0 and s["final_balance"] == -18.0  # week 1's 30 was payable, nothing carried
    assert (s["payable_bonus"], s["carry_forward_balance"]) == (0.0, -18.0)


def test_weekly_difference_drives_carry_forward_and_history_stays_per_week(a):
    r1, w1 = a.run_week([("Sam", 1000)], "w1.pdf")     # win 1000 -> -30 carried
    _, w2 = a.run_week([("Sam", 1000)], "w2.pdf")      # unchanged cumulative -> no change this week
    s = w2["Sam"]
    assert (s["weekly_change"], s["personal_adjustment"]) == (0.0, 0.0)
    assert (s["previous_balance"], s["final_balance"], s["carry_forward_balance"]) == (-30.0, -30.0, -30.0)
    # week 1's stored figures are untouched by week 2
    old = a.results(r1)["Sam"]
    assert (old["previous_report_total"], old["weekly_change"], old["personal_adjustment"]) == (0.0, 1000.0, -30.0)
    uid = w1["Sam"]["user_id"]
    weeks = a.get(f"/users/{uid}/weeks").json()["weeks"]
    assert [(w["previous_report_total"], w["current_report_total"], w["weekly_change"]) for w in weeks] == [
        (1000.0, 1000.0, 0.0),
        (0.0, 1000.0, 1000.0),
    ]


def test_recalculating_does_not_reapply_the_difference(a):
    a.run_week([("Sam", -90)], "w1.pdf")
    rid2, w2 = a.run_week([("Sam", -100)], "w2.pdf")
    again = by_name(a.calculate(rid2).json()["results"])["Sam"]
    assert (again["weekly_change"], again["personal_adjustment"], again["previous_report_total"]) == (-10.0, 0.3, -90.0)


def test_user_absent_last_week_uses_their_last_known_total(a):
    a.run_week([("A", -1000)], "w1.pdf")
    a.run_week([("B", -1)], "w2.pdf")                  # A absent
    _, w3 = a.run_week([("A", -1500)], "w3.pdf")
    assert (w3["A"]["previous_report_total"], w3["A"]["weekly_change"]) == (-1000.0, -500.0)


def test_referral_uses_the_referred_users_weekly_difference(a):
    rid1 = a.upload([("Boss", 0), ("R1", -4000)], "w1.pdf").json()["report_id"]
    a.calculate(rid1)
    rid2 = a.upload([("Boss", 0), ("R1", -10000)], "w2.pdf").json()["report_id"]
    u = {n: r["user_id"] for n, r in a.results(rid2).items()}
    a.post(f"/reports/{rid2}/referrals", json={"referrer_user_id": u["Boss"], "referred_user_id": u["R1"]})
    boss = by_name(a.calculate(rid2).json()["results"])
    assert boss["R1"]["weekly_change"] == -6000.0
    assert boss["Boss"]["referral_adjustment"] == 600.0   # 10% of the 6,000 lost this week, not of 10,000
