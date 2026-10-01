-- =============================================================================
-- Numberspeaks — Per-account data isolation: owner_id on reports and users
-- =============================================================================
-- Run this once in the Supabase SQL Editor, BEFORE deploying the backend that
-- enforces ownership (the upload endpoint now writes reports.owner_id).
-- Purely additive: no existing row or column value is changed.
--
--   reports.owner_id  the Supabase Auth user who uploaded the report. Every
--                     report endpoint (status / validate / calculate-bonus /
--                     results / send-whatsapp) only serves a report to its
--                     owner, or to an admin.
--   users.owner_id    the account whose report listed this person. Recipients
--                     are matched by name only within one account, so one
--                     account's upload can no longer reuse or overwrite
--                     another account's recipients (level / WhatsApp number).
--
-- Rows that already exist keep owner_id = NULL. Such reports are visible to
-- admins only. To hand them to the right account, run (per report):
--     update public.reports set owner_id = '<auth user uuid>' where id = '<report uuid>';
-- Their recipients stay NULL-owned, and a report with no owner keeps matching
-- NULL-owned recipients, so those reports keep working unchanged.
-- =============================================================================

alter table public.reports
    add column if not exists owner_id uuid references auth.users(id) on delete set null;

alter table public.users
    add column if not exists owner_id uuid references auth.users(id) on delete set null;

create index if not exists idx_reports_owner_id on public.reports(owner_id);
create index if not exists idx_users_owner_id_name on public.users(owner_id, name);
