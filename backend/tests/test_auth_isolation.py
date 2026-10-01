"""
Tests that each account only reaches its own reports, and that the bearer
token is really verified against Supabase Auth.

Run from the backend/ folder:
    venv/bin/python -m unittest tests.test_auth_isolation -v
"""

import unittest
import uuid
from unittest.mock import patch

import httpx

from app.core import auth
from app.core.auth import AuthUser, get_current_user
from app.main import app
from app.schemas.report import ExtractedRecord
from app.services.pdf_extractor import ExtractionResult
from tests.test_report_pipeline import PipelineTestCase

USER_A = AuthUser(id="aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa", email="a@example.com")
USER_B = AuthUser(id="bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb", email="b@example.com")
ADMIN = AuthUser(id="cccccccc-cccc-cccc-cccc-cccccccccccc", email="admin@example.com", is_admin=True)


def _records(number="9000000001"):
    return [
        ExtractedRecord(no=1, user_name="Alice", whatsapp_number=number, level="L1", casino_pts=0,
                        sport_pts=0, third_party_pts=0, profit_loss=-1000.0, ptype="P", source_page=1),
        ExtractedRecord(no=2, user_name="Bob", whatsapp_number="9000000002", level="L2", casino_pts=0,
                        sport_pts=0, third_party_pts=0, profit_loss=500.0, ptype="P", source_page=1),
    ]


class IsolationTests(PipelineTestCase):
    def upload_as(self, user, number="9000000001"):
        self.user = user
        extraction = ExtractionResult(records=_records(number), pages_processed=1, warnings=[])
        with patch("app.services.report_processor.extract_records_from_pdf", lambda *_a, **_k: extraction):
            report_id = self.upload(b"%PDF-1.4 x").json()["report_id"]
            final, _ = self.wait_final(report_id)
        self.assertEqual(final["status"], "completed", final)
        return report_id

    def api(self, method, path, **kw):
        return getattr(self.client, method)(f"/api/v1{path}", **kw)

    def test_upload_records_the_owner(self):
        report_id = self.upload_as(USER_A)
        report = next(r for r in self.db.tables["reports"] if r["id"] == report_id)
        self.assertEqual(report["owner_id"], USER_A.id)

    def test_other_account_gets_404_on_every_report_endpoint(self):
        report_id = self.upload_as(USER_A)
        bonus_result = self.db.tables["bonus_results"][0]

        # Owner can use all of them.
        self.user = USER_A
        self.assertEqual(self.api("get", f"/reports/{report_id}/status").status_code, 200)
        self.assertEqual(len(self.api("get", f"/reports/{report_id}/results").json()), 2)
        self.assertEqual(
            self.api("get", f"/reports/{report_id}/results/{bonus_result['user_id']}").status_code, 200)

        # Another account cannot see that it exists.
        self.user = USER_B
        unknown = uuid.uuid4()
        calls = [
            ("get", f"/reports/{report_id}/status", f"/reports/{unknown}/status"),
            ("get", f"/reports/{report_id}/results", f"/reports/{unknown}/results"),
            ("get", f"/reports/{report_id}/results/{bonus_result['user_id']}",
             f"/reports/{unknown}/results/{bonus_result['user_id']}"),
            ("post", f"/reports/{report_id}/validate", f"/reports/{unknown}/validate"),
            ("post", f"/reports/{report_id}/calculate-bonus", f"/reports/{unknown}/calculate-bonus"),
            ("post", f"/reports/{report_id}/send-whatsapp", f"/reports/{unknown}/send-whatsapp"),
        ]
        for method, foreign, missing in calls:
            r = self.api(method, foreign)
            self.assertEqual(r.status_code, 404, foreign)
            # Identical to a report that does not exist, apart from the id echoed back.
            self.assertEqual(r.json()["detail"].replace(report_id, "X"),
                             self.api(method, missing).json()["detail"].replace(str(unknown), "X"))

        # And nothing was changed by the rejected calls.
        report = next(r for r in self.db.tables["reports"] if r["id"] == report_id)
        self.assertEqual(report["status"], "completed")
        self.assertEqual(self.db.requests[("whatsapp_messages", "insert")], 0)

    def test_each_account_has_its_own_reports_and_recipients(self):
        a = self.upload_as(USER_A, number="9000000001")
        b = self.upload_as(USER_B, number="9111111111")  # same names, different number

        # Two separate sets of recipients; A's were not reused or overwritten.
        users = self.db.tables["users"]
        self.assertEqual(len(users), 4)
        self.assertEqual({u["owner_id"] for u in users}, {USER_A.id, USER_B.id})
        self.user = USER_A
        a_rows = self.api("get", f"/reports/{a}/results").json()
        self.assertEqual({r["whatsapp_number"] for r in a_rows if r["user_name"] == "Alice"}, {"9000000001"})
        self.user = USER_B
        b_rows = self.api("get", f"/reports/{b}/results").json()
        self.assertEqual({r["whatsapp_number"] for r in b_rows if r["user_name"] == "Alice"}, {"9111111111"})
        self.assertEqual(self.api("get", f"/reports/{a}/results").status_code, 404)

    def test_admin_can_access_every_report(self):
        a = self.upload_as(USER_A)
        b = self.upload_as(USER_B)
        self.user = ADMIN
        for report_id in (a, b):
            self.assertEqual(self.api("get", f"/reports/{report_id}/status").status_code, 200)
            self.assertEqual(len(self.api("get", f"/reports/{report_id}/results").json()), 2)

    def test_report_without_owner_is_admin_only(self):
        report_id = self.upload_as(USER_A)
        next(r for r in self.db.tables["reports"] if r["id"] == report_id)["owner_id"] = None
        self.user = USER_A
        self.assertEqual(self.api("get", f"/reports/{report_id}/results").status_code, 404)
        self.user = ADMIN
        self.assertEqual(self.api("get", f"/reports/{report_id}/results").status_code, 200)

    def test_report_list_is_the_accounts_own_and_survives_logout_login(self):
        a = self.upload_as(USER_A)
        b = self.upload_as(USER_B)

        self.user = USER_A
        listed = self.api("get", "/reports").json()
        self.assertEqual([r["report_id"] for r in listed], [a])
        self.assertEqual((listed[0]["status"], listed[0]["total_records"]), ("completed", 2))
        self.user = USER_B
        self.assertEqual([r["report_id"] for r in self.api("get", "/reports").json()], [b])

        # Only admins may ask for everyone's; an admin's default is their own.
        self.assertEqual(self.api("get", "/reports?all=true").status_code, 403)
        self.user = ADMIN
        self.assertEqual(self.api("get", "/reports").json(), [])
        self.assertEqual({r["report_id"] for r in self.api("get", "/reports?all=true").json()}, {a, b})

    def test_results_of_a_report_that_does_not_exist_is_404(self):
        self.user = USER_A
        r = self.api("get", f"/reports/{uuid.uuid4()}/results")
        self.assertEqual(r.status_code, 404)
        self.assertIn("No report found", r.json()["detail"])


class TokenVerificationTests(unittest.TestCase):
    """The real get_current_user (no dependency override), with Supabase Auth faked."""

    def setUp(self):
        from fastapi.testclient import TestClient

        auth._cache.clear()
        app.dependency_overrides.pop(get_current_user, None)
        self.client = TestClient(app)
        self.settings = patch.multiple(
            auth.get_settings(), SUPABASE_URL="https://x.supabase.co", SUPABASE_KEY="service-key",
            ADMIN_USER_IDS="",
        )
        self.settings.start()
        self.calls = []

    def tearDown(self):
        self.settings.stop()
        auth._cache.clear()

    def fake_supabase_auth(self, status_code=200, body=None):
        def fake_get(url, headers=None, timeout=None):
            self.calls.append((url, headers))
            return httpx.Response(status_code, json=body or {})
        return patch("app.core.auth.httpx.get", fake_get)

    def get_status(self, token=None):
        headers = {"Authorization": f"Bearer {token}"} if token else {}
        return self.client.get(f"/api/v1/reports/{uuid.uuid4()}/status", headers=headers)

    def test_missing_token_is_401_on_every_report_endpoint(self):
        rid = uuid.uuid4()
        for method, path in [
            ("post", "/reports/upload"), ("get", "/reports"), ("get", f"/reports/{rid}/status"),
            ("post", f"/reports/{rid}/validate"), ("post", f"/reports/{rid}/calculate-bonus"),
            ("get", f"/reports/{rid}/results"), ("get", f"/reports/{rid}/results/{rid}"),
            ("post", f"/reports/{rid}/send-whatsapp"),
        ]:
            self.assertEqual(getattr(self.client, method)(f"/api/v1{path}").status_code, 401, path)

    def test_token_rejected_by_supabase_is_401(self):
        with self.fake_supabase_auth(401, {"msg": "invalid JWT"}):
            self.assertEqual(self.get_status("bad").status_code, 401)

    def test_valid_token_is_resolved_to_the_supabase_user_and_cached(self):
        body = {"id": USER_A.id, "email": "a@example.com", "app_metadata": {}}
        with self.fake_supabase_auth(200, body):
            user = auth.get_current_user(type("C", (), {"credentials": "tok"})())
            self.assertEqual((user.id, user.is_admin), (USER_A.id, False))
            self.get_status("tok")
            self.get_status("tok")
        self.assertEqual(len(self.calls), 1)  # second and third use the cache
        self.assertEqual(self.calls[0][0], "https://x.supabase.co/auth/v1/user")
        self.assertEqual(self.calls[0][1]["Authorization"], "Bearer tok")

    def test_admin_from_app_metadata_or_env(self):
        with self.fake_supabase_auth(200, {"id": "u1", "app_metadata": {"role": "admin"}}):
            self.assertTrue(auth.get_current_user(type("C", (), {"credentials": "t1"})()).is_admin)
        with patch.object(auth.get_settings(), "ADMIN_USER_IDS", "u2, u3"):
            with self.fake_supabase_auth(200, {"id": "u3", "app_metadata": {}}):
                self.assertTrue(auth.get_current_user(type("C", (), {"credentials": "t2"})()).is_admin)
        # user_metadata is editable by the user, so it must never grant admin.
        with self.fake_supabase_auth(200, {"id": "u4", "app_metadata": {}, "user_metadata": {"role": "admin"}}):
            self.assertFalse(auth.get_current_user(type("C", (), {"credentials": "t3"})()).is_admin)

    def test_supabase_outage_is_503_not_access(self):
        with patch("app.core.auth.httpx.get", side_effect=httpx.ConnectError("down")):
            self.assertEqual(self.get_status("tok").status_code, 503)


if __name__ == "__main__":
    unittest.main()
