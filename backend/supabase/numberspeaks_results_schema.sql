-- Numberspeaks — Supabase schema for durable report/result storage
-- ====================================================================
-- Run this ONCE in your Supabase project's SQL editor (the same project
-- this app already uses for login — see .env's SUPABASE_URL).
--
-- IMPORTANT — fixes a table-name collision from the first version of this
-- script: your Supabase project's Postgres database already has its own
-- `public.bonus_results` table (and very likely `public.reports` too) —
-- almost certainly owned by the FastAPI backend itself (its schema has a
-- `user_id` column, not `owner_id`, which is what the error you hit was
-- pointing at). The first version of this script tried to reuse those
-- exact names, which is wrong — this app's own persistence must never
-- share a table with something the backend already manages. This version
-- uses different, clearly-app-owned names instead: `ns_reports` and
-- `ns_bonus_results`. It does not read, write, alter, or rename anything
-- in your existing `reports`/`bonus_results` tables.
--
-- Is anything left over from the failed run? No action needed — Supabase's
-- SQL editor runs a whole pasted script as one transaction, so the error
-- you hit rolled back every statement before it in that same run,
-- including the `enable row level security` line that touched your
-- existing `bonus_results` table. Nothing in your database was actually
-- changed. (If you want to confirm this yourself first, run:
-- `select relrowsecurity from pg_class where relname = 'bonus_results';`
-- — it should say `false`, i.e. unchanged from before you ran anything.)
--
-- Access model (read this before running):
-- Every row is scoped to `owner_id = auth.uid()` — the signed-in admin who
-- uploaded it. That means each admin account only ever sees the reports
-- and results THEY uploaded, never another admin's. This is this round's
-- best-effort reading of "available ... as allowed by the user's access"
-- for an app with one login-based role. If instead you want every signed-in
-- admin to see every report (one shared pool), change every
-- `using (owner_id = auth.uid())` / `with check (owner_id = auth.uid())`
-- below to `using (auth.uid() is not null)` / `with check (auth.uid() is
-- not null)` and re-run — nothing in the Flutter app needs to change
-- either way, since it never filters by owner itself (RLS does that).
-- ====================================================================

create extension if not exists pgcrypto;

-- One row per uploaded report (mirrors what the FastAPI backend returns
-- from /upload, /validate, /calculate-bonus — just the small summary
-- fields, never re-deriving anything). Deliberately NOT named "reports" —
-- see the note above.
create table if not exists public.ns_reports (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references auth.users(id) on delete cascade,
  report_id text not null,                 -- the FastAPI backend's own id for this report
  file_name text not null default '',
  status text not null default '',
  total_records integer,
  bonus_eligible_count integer,
  total_bonus numeric,
  pdf_storage_path text,                   -- set once the PDF itself is uploaded to Storage below
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (owner_id, report_id)
);

-- One row per user per report — mirrors BonusResult (app/schemas/bonus.py)
-- field for field, plus `whatsapp_number` which here can also hold a
-- number the admin typed in by hand (the FastAPI backend has no field/
-- endpoint for that — see README). Deliberately NOT named "bonus_results"
-- — see the note above.
create table if not exists public.ns_bonus_results (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references auth.users(id) on delete cascade,
  report_id text not null,
  bonus_result_id text not null,           -- the FastAPI backend's own id for this result row
  user_id text not null,
  user_name text not null default '',
  level text,
  casino_pts numeric not null default 0,
  sport_pts numeric not null default 0,
  third_party_pts numeric not null default 0,
  profit_loss numeric not null default 0,
  ptype text,
  bonus_amount numeric,                    -- null = not calculated; 0 = calculated, nothing owed
  calculation_status text not null default 'pending',
  whatsapp_status text not null default 'not_sent',
  whatsapp_number text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (owner_id, report_id, bonus_result_id)
);

alter table public.ns_reports enable row level security;
alter table public.ns_bonus_results enable row level security;

drop policy if exists "Owner can read own reports" on public.ns_reports;
drop policy if exists "Owner can insert own reports" on public.ns_reports;
drop policy if exists "Owner can update own reports" on public.ns_reports;

create policy "Owner can read own reports" on public.ns_reports
  for select using (owner_id = auth.uid());
create policy "Owner can insert own reports" on public.ns_reports
  for insert with check (owner_id = auth.uid());
create policy "Owner can update own reports" on public.ns_reports
  for update using (owner_id = auth.uid()) with check (owner_id = auth.uid());

drop policy if exists "Owner can read own results" on public.ns_bonus_results;
drop policy if exists "Owner can insert own results" on public.ns_bonus_results;
drop policy if exists "Owner can update own results" on public.ns_bonus_results;

create policy "Owner can read own results" on public.ns_bonus_results
  for select using (owner_id = auth.uid());
create policy "Owner can insert own results" on public.ns_bonus_results
  for insert with check (owner_id = auth.uid());
create policy "Owner can update own results" on public.ns_bonus_results
  for update using (owner_id = auth.uid()) with check (owner_id = auth.uid());

-- Storage for the uploaded PDF itself ("save the uploaded PDF ... in
-- Supabase"). Private bucket — not world-readable; only reachable by the
-- owning admin's own session, via path-prefix ownership ($uid/$reportId/
-- $fileName), the standard Supabase Storage RLS pattern. Bucket names are
-- a separate namespace from Postgres tables, so no collision risk here —
-- left as-is.
insert into storage.buckets (id, name, public)
values ('report-pdfs', 'report-pdfs', false)
on conflict (id) do nothing;

drop policy if exists "Owner can upload own report PDFs" on storage.objects;
drop policy if exists "Owner can read own report PDFs" on storage.objects;
drop policy if exists "Owner can overwrite own report PDFs" on storage.objects;

create policy "Owner can upload own report PDFs" on storage.objects
  for insert with check (
    bucket_id = 'report-pdfs'
    and (storage.foldername(name))[1] = auth.uid()::text
  );
create policy "Owner can read own report PDFs" on storage.objects
  for select using (
    bucket_id = 'report-pdfs'
    and (storage.foldername(name))[1] = auth.uid()::text
  );
create policy "Owner can overwrite own report PDFs" on storage.objects
  for update using (
    bucket_id = 'report-pdfs'
    and (storage.foldername(name))[1] = auth.uid()::text
  );
