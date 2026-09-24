-- =============================================================================
-- Numberspeaks — Step 2: Core database schema
-- =============================================================================
-- Run this in the Supabase SQL Editor (or via `supabase db push` / migrations)
-- on a fresh project. Safe to re-run: tables are only created if missing.
--
-- Tables:
--   users          -> people who appear in the "Party Profit Loss" report
--                     and receive bonus payouts over WhatsApp.
--   reports        -> one row per uploaded PDF report.
--   bonus_results  -> one row per user, per report: the extracted figures
--                     and (later) the calculated bonus.
--
-- No bonus formula, WhatsApp logic, or PDF parsing lives here — this is
-- storage only.
-- =============================================================================

-- Required for gen_random_uuid()
create extension if not exists pgcrypto;

-- -----------------------------------------------------------------------------
-- users
-- -----------------------------------------------------------------------------
-- Represents a person listed in the client's report (the "User Name" /
-- "Level" columns), not an admin/staff login. Authorized access for people
-- who upload reports (e.g. staff) is handled separately via Supabase Auth —
-- see the note in README.md; no extra table is needed for that yet.
create table if not exists public.users (
    id               uuid primary key default gen_random_uuid(),
    name             text not null,
    level            text,
    whatsapp_number  text,
    is_active        boolean not null default true,
    created_at       timestamptz not null default now()
);

comment on table public.users is
    'People listed in the Party Profit Loss report who can receive bonus payouts.';

-- -----------------------------------------------------------------------------
-- reports
-- -----------------------------------------------------------------------------
-- One row per uploaded PDF. `status` tracks where the report is in the
-- pipeline; the actual upload/extraction logic is built in a later step.
create table if not exists public.reports (
    id           uuid primary key default gen_random_uuid(),
    file_name    text not null,
    file_path    text not null,
    status       text not null default 'uploaded'
                 constraint reports_status_check
                 check (status in ('uploaded', 'processing', 'validated', 'completed', 'failed')),
    uploaded_at  timestamptz not null default now()
);

comment on table public.reports is
    'One row per uploaded Party Profit Loss PDF report.';

-- -----------------------------------------------------------------------------
-- bonus_results
-- -----------------------------------------------------------------------------
-- One row per user per report: the figures extracted from the PDF, plus a
-- bonus_amount column reserved for when the client's bonus formula is
-- implemented (Step 4+). It is nullable now because no calculation exists
-- yet — null means "not yet calculated", not "zero bonus".
create table if not exists public.bonus_results (
    id                 uuid primary key default gen_random_uuid(),
    report_id          uuid not null references public.reports(id) on delete cascade,
    user_id            uuid not null references public.users(id) on delete restrict,
    casino_pts         numeric not null default 0,
    sport_pts          numeric not null default 0,
    third_party_pts    numeric not null default 0,
    profit_loss        numeric not null default 0,
    ptype              text,
    bonus_amount       numeric,
    created_at         timestamptz not null default now(),

    -- One extracted row per user per report.
    constraint bonus_results_report_user_unique unique (report_id, user_id)
);

comment on table public.bonus_results is
    'Per-user figures extracted from a report, and the resulting calculated bonus.';

-- Indexes for the foreign keys (Postgres does not create these automatically).
create index if not exists idx_bonus_results_report_id on public.bonus_results(report_id);
create index if not exists idx_bonus_results_user_id on public.bonus_results(user_id);

-- -----------------------------------------------------------------------------
-- Row Level Security
-- -----------------------------------------------------------------------------
-- The FastAPI backend talks to Supabase using the service role key, which
-- always bypasses RLS — so enabling RLS here with no policies simply means
-- no one else (anon/public clients) can read or write these tables directly.
-- This is the safe default for data that should only ever go through the API.
alter table public.users enable row level security;
alter table public.reports enable row level security;
alter table public.bonus_results enable row level security;
