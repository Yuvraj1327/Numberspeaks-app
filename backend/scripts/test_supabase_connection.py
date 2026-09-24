"""
Manual Supabase connection test.

Run this once after:
  1. Creating a Supabase project.
  2. Running supabase/schema.sql in the Supabase SQL Editor.
  3. Filling in SUPABASE_URL and SUPABASE_KEY in your .env file.

It proves the three things Step 2 requires:
  - FastAPI (this script uses the same client code the API uses) can
    connect to Supabase.
  - Data can be inserted (into all three tables, respecting the
    relationships between them).
  - Data can be read back successfully.

It cleans up every row it creates, so it's safe to run against a real
project and leaves no test data behind.

Usage:
    python -m scripts.test_supabase_connection
"""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from app.db.supabase_client import SupabaseNotConfiguredError, get_supabase  # noqa: E402


def main() -> None:
    print("1. Connecting to Supabase...")
    try:
        db = get_supabase()
    except SupabaseNotConfiguredError as exc:
        print(f"   FAILED: {exc}")
        sys.exit(1)
    except Exception as exc:  # noqa: BLE001 - e.g. malformed URL/key
        print(f"   FAILED: could not create Supabase client — {exc}")
        print("   Check that SUPABASE_URL and SUPABASE_KEY in .env are correct.")
        sys.exit(1)
    print("   OK — client created.")

    test_user_id = None
    test_report_id = None

    try:
        print("2. Inserting a test user...")
        user_res = (
            db.table("users")
            .insert({
                "name": "__connection_test_user__",
                "level": "Test",
                "whatsapp_number": "+10000000000",
                "is_active": True,
            })
            .execute()
        )
        test_user_id = user_res.data[0]["id"]
        print(f"   OK — inserted user id={test_user_id}")

        print("3. Inserting a test report...")
        report_res = (
            db.table("reports")
            .insert({
                "file_name": "__connection_test__.pdf",
                "file_path": "/tmp/__connection_test__.pdf",
                "status": "uploaded",
            })
            .execute()
        )
        test_report_id = report_res.data[0]["id"]
        print(f"   OK — inserted report id={test_report_id}")

        print("4. Inserting a linked bonus_results row...")
        db.table("bonus_results").insert({
            "report_id": test_report_id,
            "user_id": test_user_id,
            "casino_pts": 10,
            "sport_pts": 5,
            "third_party_pts": 0,
            "profit_loss": 15,
            "ptype": "User",
        }).execute()
        print("   OK — inserted bonus_results row.")

        print("5. Reading the joined data back...")
        read_res = (
            db.table("bonus_results")
            .select("*, users(name, level), reports(file_name, status)")
            .eq("user_id", test_user_id)
            .execute()
        )
        if not read_res.data:
            print("   FAILED: insert succeeded but read-back returned no rows.")
            sys.exit(1)
        print(f"   OK — read back: {read_res.data[0]}")

        print("\nAll checks passed: connection, insert, and read all work.")

    except Exception as exc:  # noqa: BLE001 - report cleanly, then still clean up below
        print(f"   FAILED: {exc}")
        print(
            "   If this mentions a missing table or relation, make sure "
            "supabase/schema.sql has been run on this project."
        )
        raise

    finally:
        print("6. Cleaning up test data...")
        try:
            if test_report_id:
                db.table("bonus_results").delete().eq("report_id", test_report_id).execute()
                db.table("reports").delete().eq("id", test_report_id).execute()
            if test_user_id:
                db.table("users").delete().eq("id", test_user_id).execute()
            print("   Done.")
        except Exception as cleanup_exc:  # noqa: BLE001
            print(f"   Cleanup skipped/incomplete: {cleanup_exc}")


if __name__ == "__main__":
    main()
