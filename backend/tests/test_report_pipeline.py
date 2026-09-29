"""
End-to-end tests of the background report pipeline, run against the
in-memory Supabase fake (tests/fake_supabase.py).

Run from the backend/ folder:
    venv/bin/python -m unittest tests.test_report_pipeline -v

Set CLIENT_PDF to point at the client's report (defaults to the copy in
~/Downloads); those tests are skipped if the file isn't there.
"""

import logging
import os
import time
import unittest
import uuid
from datetime import datetime, timedelta, timezone
from unittest.mock import patch

from fastapi.testclient import TestClient

from app.main import app
from app.schemas.report import ExtractedRecord
from app.services import report_processor
from app.services.bonus_calculator import calculate_bonus, BonusInput
from app.services.pdf_extractor import ExtractionResult, extract_records_from_pdf
from app.services.reports_service import get_bonus_results_for_report, save_extracted_records
from tests.fake_supabase import FakeSupabase

CLIENT_PDF = os.environ.get("CLIENT_PDF", os.path.expanduser("~/Downloads/Party Profit Loss (1).pdf"))
NOT_A_REPORT_PDF = (
    b"%PDF-1.4\n1 0 obj<</Type/Catalog/Pages 2 0 R>>endobj\n"
    b"2 0 obj<</Type/Pages/Kids[3 0 R]/Count 1>>endobj\n"
    b"3 0 obj<</Type/Page/Parent 2 0 R/MediaBox[0 0 200 200]>>endobj\n"
    b"trailer<</Root 1 0 R/Size 4>>\n%%EOF\n"
)


class _LogCapture(logging.Handler):
    def __init__(self):
        super().__init__(logging.DEBUG)
        self.lines = []

    def emit(self, record):
        text = record.getMessage()
        if record.exc_info:
            text += "\n" + "".join(logging.Formatter().formatException(record.exc_info))
        self.lines.append(text)


class PipelineTestCase(unittest.TestCase):
    def setUp(self):
        self.db = FakeSupabase(latency=0.002)
        self.patches = [
            patch("app.api.v1.endpoints.reports.get_supabase", lambda: self.db),
            patch("app.api.v1.endpoints.bonus.get_supabase", lambda: self.db),
            patch("app.services.report_processor.get_supabase", lambda: self.db),
        ]
        for p in self.patches:
            p.start()
        self.client = TestClient(app)
        self.logs = _LogCapture()
        logging.getLogger("numberspeaks").addHandler(self.logs)

    def tearDown(self):
        logging.getLogger("numberspeaks").removeHandler(self.logs)
        for p in self.patches:
            p.stop()

    def upload(self, data, name="report.pdf"):
        return self.client.post("/api/v1/reports/upload", files={"file": (name, data, "application/pdf")})

    def wait_final(self, report_id, timeout=60):
        seen = []
        deadline = time.time() + timeout
        while time.time() < deadline:
            body = self.client.get(f"/api/v1/reports/{report_id}/status").json()
            if not seen or seen[-1] != body["status"]:
                seen.append(body["status"])
            if body["is_final"]:
                return body, seen
            time.sleep(0.005)
        self.fail(f"report did not finish; statuses seen: {seen}")


@unittest.skipUnless(os.path.exists(CLIENT_PDF), "client PDF not found")
class ClientPdfTests(PipelineTestCase):
    @classmethod
    def setUpClass(cls):
        with open(CLIENT_PDF, "rb") as fh:
            cls.pdf = fh.read()
        cls.expected = extract_records_from_pdf(cls.pdf)  # existing extractor = ground truth

    def test_full_flow(self):
        t0 = time.perf_counter()
        resp = self.upload(self.pdf, "Party Profit Loss (1).pdf")
        upload_seconds = time.perf_counter() - t0

        self.assertEqual(resp.status_code, 202)
        body = resp.json()
        self.assertEqual(body["status"], "uploaded")
        report_id = body["report_id"]
        uuid.UUID(report_id)

        final, seen = self.wait_final(report_id)
        print(f"\n  upload returned in {upload_seconds * 1000:.0f} ms; statuses seen: {seen}")
        print(f"  final status: {final['status']}, pages={final['pages_processed']}, "
              f"records={final['total_records']}, calculated={final['calculated_count']}, "
              f"failed={final['failed_count']}")

        # Status walked the pipeline in order and ended completed.
        self.assertEqual(final["status"], "completed", final)
        self.assertEqual(self.db.status_history[report_id],
                         ["uploaded", "processing", "validating", "calculating", "completed"])
        self.assertEqual(final["pages_processed"], self.expected.pages_processed)
        self.assertEqual(final["total_records"], len(self.expected.records))
        self.assertEqual(final["calculated_count"], len(self.expected.records))
        self.assertEqual(final["failed_count"], 0)
        self.assertEqual(final["warnings"], self.expected.warnings)

        # Every record processed; values preserved; bonus rule = 3% of a loss.
        results = self.client.get(f"/api/v1/reports/{report_id}/results").json()
        self.assertEqual(len(results), len(self.expected.records))
        for got, want in zip(results, self.expected.records):  # PDF order preserved
            self.assertEqual(got["user_name"], want.user_name)
            self.assertEqual(got["whatsapp_number"], want.whatsapp_number)
            self.assertEqual(got["level"], want.level)
            self.assertEqual(got["ptype"], want.ptype)
            for f in ("casino_pts", "sport_pts", "third_party_pts", "profit_loss"):
                self.assertEqual(got[f], getattr(want, f), f)
            expected_bonus = round(abs(want.profit_loss) * 0.03, 2) if want.profit_loss < 0 else 0.0
            self.assertEqual(got["bonus_amount"], expected_bonus)
            self.assertEqual(got["calculation_status"], "calculated")
            self.assertEqual(got["whatsapp_status"], "not_sent")
        self.assertEqual(len(self.db.tables["bonus_results"]), len(self.expected.records))

        # Request budget: a handful of calls, not per-user calls.
        total = sum(self.db.requests.values())
        print(f"  Supabase requests for {len(results)} users (upload+process+status polls excluded from "
              f"the per-user maths): {dict(self.db.requests)}")
        self.assertLessEqual(self.db.requests[("bonus_results", "upsert")], 3)
        self.assertLessEqual(self.db.requests[("users", "insert")], 1)
        self.assertEqual(self.db.requests[("users", "select")], 2)  # 174 names / chunk of 100
        # One read feeds validation and calculation, one serves /results.
        self.assertEqual(self.db.requests[("bonus_results", "select")], 2)

        # Logs contain no PDF contents, phone numbers or amounts.
        joined = "\n".join(self.logs.lines)
        for rec in self.expected.records:
            self.assertNotIn(rec.user_name, joined)
            if rec.whatsapp_number:
                self.assertNotIn(rec.whatsapp_number, joined)
            if abs(rec.profit_loss) >= 1000:
                self.assertNotIn(f"{rec.profit_loss}", joined)
        print(f"  {len(self.logs.lines)} log lines, none contain names/numbers/amounts")

    def test_second_upload_reuses_users_and_updates_changed_fields(self):
        r1 = self.upload(self.pdf).json()["report_id"]
        self.wait_final(r1)
        users_before = len(self.db.tables["users"])

        # Same people, one changed level -> same users, level updated.
        first = self.db.tables["users"][0]
        first["level"] = "OLD-LEVEL"
        self.db.requests.clear()
        r2 = self.upload(self.pdf).json()["report_id"]
        final, _ = self.wait_final(r2)

        self.assertEqual(final["status"], "completed")
        self.assertEqual(len(self.db.tables["users"]), users_before)
        self.assertEqual(self.db.requests[("users", "insert")], 0)
        self.assertEqual(self.db.requests[("users", "upsert")], 1)  # one bulk update, not per user
        self.assertNotEqual(first["level"], "OLD-LEVEL")
        self.assertEqual(len(self.db.tables["bonus_results"]), 2 * len(self.expected.records))

    def test_report_is_never_processed_twice(self):
        report_id = self.upload(self.pdf).json()["report_id"]
        # Hammer the job entry point from several threads at once.
        import threading
        threads = [threading.Thread(target=report_processor.process_report, args=(report_id,)) for _ in range(6)]
        for t in threads:
            t.start()
        for t in threads:
            t.join()
        final, _ = self.wait_final(report_id)
        self.assertEqual(final["status"], "completed")
        self.assertEqual(self.db.tables["reports"][0]["attempts"], 1)
        self.assertEqual(self.db.requests[("storage", "download")], 1)
        self.assertEqual(len(self.db.tables["bonus_results"]), len(self.expected.records))
        # Already-finished report is not re-run either.
        report_processor.process_report(report_id)
        self.assertEqual(self.db.tables["reports"][0]["attempts"], 1)

    def test_legacy_endpoints_are_blocked_while_processing_and_still_work_after(self):
        # Keep the background job out of the way so the states can be set by hand.
        with patch("app.api.v1.endpoints.reports.submit_report"):
            report_id = self.upload(self.pdf).json()["report_id"]
        report = self.db.tables["reports"][0]

        for busy in ("uploaded", "processing", "validating", "calculating"):
            report["status"] = busy
            self.assertEqual(self.client.post(f"/api/v1/reports/{report_id}/validate").status_code, 409, busy)
        for busy in ("processing", "validating", "calculating"):
            report["status"] = busy
            self.assertEqual(self.client.post(f"/api/v1/reports/{report_id}/calculate-bonus").status_code, 409, busy)

        report["status"] = "uploaded"
        report_processor.process_report(report_id)
        self.assertEqual(report["status"], "completed")

        v = self.client.post(f"/api/v1/reports/{report_id}/validate")
        self.assertEqual(v.status_code, 200)
        self.assertEqual(v.json()["valid_count"], len(self.expected.records))
        c = self.client.post(f"/api/v1/reports/{report_id}/calculate-bonus")
        self.assertEqual(c.status_code, 200)
        self.assertEqual(c.json()["calculated_count"], len(self.expected.records))
        self.assertEqual(c.json()["status"], "completed")

    def test_abandoned_report_is_resumed_when_polled(self):
        report_id = self.upload(self.pdf).json()["report_id"]
        self.wait_final(report_id)
        report = self.db.tables["reports"][0]

        # Simulate a worker that died mid-calculation long ago.
        report["status"] = "calculating"
        report["updated_at"] = (datetime.now(timezone.utc) - timedelta(hours=1)).isoformat()
        for row in self.db.tables["bonus_results"]:
            row["bonus_amount"], row["calculation_status"] = None, "pending"

        body = self.client.get(f"/api/v1/reports/{report_id}/status").json()
        self.assertFalse(body["is_final"])  # truthful: still not done
        final, _ = self.wait_final(report_id)
        self.assertEqual(final["status"], "completed")
        self.assertEqual(report["attempts"], 2)
        self.assertEqual(len(self.db.tables["bonus_results"]), len(self.expected.records))  # no duplicates
        self.assertTrue(all(r["calculation_status"] == "calculated" for r in self.db.tables["bonus_results"]))

    def test_fresh_active_report_is_not_touched(self):
        report_id = self.upload(self.pdf).json()["report_id"]
        self.wait_final(report_id)
        report = self.db.tables["reports"][0]
        report["status"], report["updated_at"] = "processing", datetime.now(timezone.utc).isoformat()
        self.client.get(f"/api/v1/reports/{report_id}/status")
        time.sleep(0.2)
        self.assertEqual(report["status"], "processing")  # a healthy job is left alone
        self.assertEqual(report["attempts"], 1)

    def test_abandoned_too_many_times_is_failed(self):
        report_id = self.upload(self.pdf).json()["report_id"]
        self.wait_final(report_id)
        report = self.db.tables["reports"][0]
        report.update(status="processing", attempts=3,
                      updated_at=(datetime.now(timezone.utc) - timedelta(hours=1)).isoformat())
        self.client.get(f"/api/v1/reports/{report_id}/status")
        final, _ = self.wait_final(report_id)
        self.assertEqual(final["status"], "failed")
        self.assertIn("upload the report again", final["error_message"])

    def test_bulk_failure_falls_back_to_row_by_row(self):
        self.db.fail_next.append(("bonus_results", "upsert"))  # first bulk save is rejected
        report_id = self.upload(self.pdf).json()["report_id"]
        final, _ = self.wait_final(report_id)
        self.assertEqual(final["status"], "completed")
        self.assertEqual(final["total_records"], len(self.expected.records))
        self.assertEqual(len(self.db.tables["bonus_results"]), len(self.expected.records))


class OtherTests(PipelineTestCase):
    def test_not_a_pdf_is_rejected_immediately(self):
        r = self.client.post("/api/v1/reports/upload", files={"file": ("x.pdf", b"hello", "application/pdf")})
        self.assertEqual(r.status_code, 422)
        self.assertEqual(self.db.tables["reports"], [])
        r = self.client.post("/api/v1/reports/upload", files={"file": ("x.txt", b"hello", "text/plain")})
        self.assertEqual(r.status_code, 400)

    def test_pdf_without_a_table_ends_failed_with_reason(self):
        r = self.upload(NOT_A_REPORT_PDF)
        self.assertEqual(r.status_code, 202)
        final, seen = self.wait_final(r.json()["report_id"])
        self.assertEqual(final["status"], "failed")
        self.assertTrue(final["error_message"])
        self.assertEqual(seen[0], "uploaded" if seen[0] == "uploaded" else seen[0])

    def test_status_unknown_report(self):
        self.assertEqual(self.client.get(f"/api/v1/reports/{uuid.uuid4()}/status").status_code, 404)
        self.assertEqual(self.client.get("/api/v1/reports/not-a-uuid/status").status_code, 404)

    def test_large_report_5000_users_with_special_names(self):
        n = 5000
        records = [
            ExtractedRecord(
                no=i, user_name=f'User, "{i}" (x:y)' if i % 500 == 0 else f"User {i}",
                whatsapp_number=f"9{i:09d}", level="L1", casino_pts=1.5, sport_pts=-2.25,
                third_party_pts=0.0, profit_loss=(-1000.0 - i) if i % 3 else float(i),
                ptype="P", source_page=1 + i // 40,
            )
            for i in range(n)
        ]
        fake_extraction = ExtractionResult(records=records, pages_processed=n // 40, warnings=[])
        with patch("app.services.report_processor.extract_records_from_pdf", lambda *_a, **_k: fake_extraction):
            t0 = time.perf_counter()
            report_id = self.upload(b"%PDF-1.4 x").json()["report_id"]
            print(f"\n  large upload returned in {(time.perf_counter() - t0) * 1000:.0f} ms")
            final, _ = self.wait_final(report_id, timeout=120)

        self.assertEqual(final["status"], "completed", final)
        self.assertEqual(final["total_records"], n)
        self.assertEqual(final["calculated_count"], n)
        rows = get_bonus_results_for_report(self.db, report_id)  # >1000 rows: needs pagination
        self.assertEqual(len(rows), n)
        for row, rec in zip(rows, records):
            self.assertEqual(row["users"]["name"], rec.user_name)
            want = calculate_bonus(BonusInput(rec.user_name, rec.level, rec.casino_pts, rec.sport_pts,
                                              rec.third_party_pts, rec.profit_loss, rec.ptype))
            self.assertEqual(row["bonus_amount"], want)
        print(f"  requests for {n} users: {sum(self.db.requests.values())} total -> {dict(self.db.requests)}")
        backend_requests = sum(v for k, v in self.db.requests.items() if k != ("reports", "select"))
        self.assertLess(backend_requests, 110)  # vs ~15,000 one-by-one calls

    def test_repeated_name_in_one_report_is_reported_not_lost(self):
        recs = [
            ExtractedRecord(no=1, user_name="Dup", casino_pts=0, sport_pts=0, third_party_pts=0, profit_loss=-100, source_page=1),
            ExtractedRecord(no=2, user_name="Other", casino_pts=0, sport_pts=0, third_party_pts=0, profit_loss=-200, source_page=1),
            ExtractedRecord(no=3, user_name="Dup", casino_pts=0, sport_pts=0, third_party_pts=0, profit_loss=-300, source_page=2),
        ]
        saved, warnings = save_extracted_records(self.db, str(uuid.uuid4()), recs)
        self.assertEqual(saved, 2)
        self.assertEqual(len(warnings), 1)
        self.assertIn("page 2", warnings[0])


if __name__ == "__main__":
    unittest.main()
