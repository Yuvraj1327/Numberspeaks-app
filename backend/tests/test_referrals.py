"""Referral entries: math, separation from personal, duplicate prevention."""

import pytest


def make_week(a, rows, name="w.pdf"):
    rid = a.upload(rows, name).json()["report_id"]
    users = a.results(rid)
    return rid, {n: r["user_id"] for n, r in users.items()}


def add(a, rid, referrer, referred, **extra):
    return a.post(f"/reports/{rid}/referrals", json={"referrer_user_id": referrer, "referred_user_id": referred, **extra})


def test_default_rate_is_ten_percent_and_stored_per_entry(a):
    rid, u = make_week(a, [("Boss", 0), ("R1", -4000)])
    r = add(a, rid, u["Boss"], u["R1"])
    assert r.status_code == 201, r.text
    e = r.json()
    assert e["rate"] == 0.10 and e["referrer_name"] == "Boss" and e["referred_name"] == "R1"
    assert e["report_id"] == rid and e["adjustment"] is None  # not computed until the admin confirms


def test_client_example_referred_users_lose_10000_gives_plus_1000(a):
    rid, u = make_week(a, [("Boss", 0), ("R1", -6000), ("R2", -4000)])
    add(a, rid, u["Boss"], u["R1"])
    add(a, rid, u["Boss"], u["R2"])
    calc = a.calculate(rid).json()
    boss = {r["user_name"]: r for r in calc["results"]}["Boss"]
    assert boss["referral_adjustment"] == 1000.0
    assert boss["personal_adjustment"] == 0.0   # kept separate from the personal figure
    assert boss["final_balance"] == 1000.0 and boss["payable_bonus"] == 1000.0


def test_referred_win_is_negative_and_stored_on_the_entry(a):
    rid, u = make_week(a, [("Boss", -1000), ("R1", 10000)])
    e = add(a, rid, u["Boss"], u["R1"]).json()
    calc = a.calculate(rid).json()
    boss = {r["user_name"]: r for r in calc["results"]}["Boss"]
    assert boss["personal_adjustment"] == 30.0 and boss["referral_adjustment"] == -1000.0
    assert boss["final_balance"] == -970.0 and boss["payable_bonus"] == 0.0 and boss["carry_forward_balance"] == -970.0

    listed = a.get(f"/reports/{rid}/referrals").json()
    assert listed[0]["entry_id"] == e["entry_id"]
    assert listed[0]["amount"] == 10000.0 and listed[0]["adjustment"] == -1000.0 and listed[0]["calculated_at"]


def test_referral_does_not_change_the_referred_users_own_bonus(a):
    rid, u = make_week(a, [("Boss", 0), ("R1", -1000)])
    add(a, rid, u["Boss"], u["R1"])
    res = {r["user_name"]: r for r in a.calculate(rid).json()["results"]}
    assert res["R1"]["personal_adjustment"] == 30.0 and res["R1"]["referral_adjustment"] == 0.0


def test_mixed_win_and_loss_net_for_the_referrer(a):
    rid, u = make_week(a, [("Boss", 0), ("R1", -5000), ("R2", 2000)])
    add(a, rid, u["Boss"], u["R1"])
    add(a, rid, u["Boss"], u["R2"])
    boss = {r["user_name"]: r for r in a.calculate(rid).json()["results"]}["Boss"]
    assert boss["referral_adjustment"] == 300.0  # +500 - 200


def test_custom_rate_per_entry_and_from_settings(a):
    rid, u = make_week(a, [("Boss", 0), ("R1", -1000), ("R2", -1000)])
    assert add(a, rid, u["Boss"], u["R1"], rate=0.2).json()["rate"] == 0.2
    a.put("/settings", json={"referral_rate": 0.05})
    assert add(a, rid, u["Boss"], u["R2"]).json()["rate"] == 0.05
    boss = {r["user_name"]: r for r in a.calculate(rid).json()["results"]}["Boss"]
    assert boss["referral_adjustment"] == 250.0  # 200 + 50


# --- duplicate prevention / double counting -------------------------------------
def test_same_pair_twice_is_rejected(a):
    rid, u = make_week(a, [("Boss", 0), ("R1", -1000)])
    assert add(a, rid, u["Boss"], u["R1"]).status_code == 201
    assert add(a, rid, u["Boss"], u["R1"]).status_code == 409
    assert len(a.get(f"/reports/{rid}/referrals").json()) == 1


def test_referred_user_cannot_be_linked_to_two_referrers_in_one_period(a):
    rid, u = make_week(a, [("Boss1", 0), ("Boss2", 0), ("R1", -1000)])
    assert add(a, rid, u["Boss1"], u["R1"]).status_code == 201
    r = add(a, rid, u["Boss2"], u["R1"])
    assert r.status_code == 409  # would count R1's loss twice
    boss = {x["user_name"]: x for x in a.calculate(rid).json()["results"]}
    assert boss["Boss1"]["referral_adjustment"] == 100.0 and boss["Boss2"]["referral_adjustment"] == 0.0


def test_recalculating_does_not_double_count_a_referral(a):
    rid, u = make_week(a, [("Boss", 0), ("R1", -1000)])
    add(a, rid, u["Boss"], u["R1"])
    for _ in range(3):
        boss = {x["user_name"]: x for x in a.calculate(rid).json()["results"]}["Boss"]
        assert boss["referral_adjustment"] == 100.0 and boss["final_balance"] == 100.0


def test_self_referral_is_rejected(a):
    rid, u = make_week(a, [("Boss", -1000)])
    assert add(a, rid, u["Boss"], u["Boss"]).status_code == 422


def test_users_must_be_in_the_report(a):
    rid, u = make_week(a, [("Boss", 0), ("R1", -1000)])
    rid2, u2 = make_week(a, [("Other", -1000)], "other.pdf")
    assert add(a, rid, u["Boss"], u2["Other"]).status_code == 422  # not in this report
    assert add(a, rid, "not-a-uuid", u["R1"]).status_code == 422


def test_rate_out_of_range_rejected(a):
    rid, u = make_week(a, [("Boss", 0), ("R1", -1000)])
    assert add(a, rid, u["Boss"], u["R1"], rate=1.5).status_code == 422
    assert add(a, rid, u["Boss"], u["R1"], rate=-0.1).status_code == 422


def test_removing_an_entry_allows_adding_it_again_and_recalculation_drops_it(a):
    rid, u = make_week(a, [("Boss", 0), ("R1", -1000)])
    e = add(a, rid, u["Boss"], u["R1"]).json()
    a.calculate(rid)
    assert a.delete(f"/reports/{rid}/referrals/{e['entry_id']}").status_code == 204
    assert a.get(f"/reports/{rid}/referrals").json() == []
    assert a.get(f"/reports/{rid}").json()["status"] == "processing"
    boss = {x["user_name"]: x for x in a.calculate(rid).json()["results"]}["Boss"]
    assert boss["referral_adjustment"] == 0.0
    assert add(a, rid, u["Boss"], u["R1"]).status_code == 201


def test_adding_an_entry_to_a_completed_report_reopens_it(a):
    rid, u = make_week(a, [("Boss", 0), ("R1", -1000)])
    a.calculate(rid)
    assert a.get(f"/reports/{rid}").json()["status"] == "completed"
    add(a, rid, u["Boss"], u["R1"])
    assert a.get(f"/reports/{rid}").json()["status"] == "processing"  # must be confirmed again
    assert a.post(f"/reports/{rid}/calculate-bonus").status_code == 409


def test_referral_adjustment_carries_into_the_next_period(a):
    rid, u = make_week(a, [("Boss", 0), ("R1", 10000)], "w1.pdf")
    add(a, rid, u["Boss"], u["R1"])
    a.calculate(rid)  # Boss: -1000 carried
    _, w2 = a.run_week([("Boss", -50000)], "w2.pdf")
    assert w2["Boss"]["previous_balance"] == -1000.0 and w2["Boss"]["final_balance"] == 500.0
