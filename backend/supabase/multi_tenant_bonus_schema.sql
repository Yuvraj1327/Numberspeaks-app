-- =============================================================================
-- Numberspeaks — Complete Bonus Management: ownership, balances, referrals,
-- history and WhatsApp-initiation tracking
-- =============================================================================
-- Run ONCE in the Supabase SQL Editor, after schema.sql, bonus_status_schema.sql
-- and whatsapp_schema.sql (the files already in this folder).
--
-- This migration is ADDITIVE ONLY and safe to re-run:
--   * no existing table is dropped, renamed or emptied;
--   * no existing row is deleted or rewritten;
--   * every ALTER uses "add column if not exists" and every CREATE uses
--     "create ... if not exists", so a second run changes nothing.
-- It runs as one transaction, so if any statement fails nothing is applied.
--
-- ---------------------------------------------------------------------------
-- STEP 0 (recommended, read-only): confirm your real schema matches what this
-- migration expects. Run this on its own first and compare:
--
--   select table_name, column_name, data_type
--   from information_schema.columns
--   where table_schema = 'public'
--     and table_name in ('users','reports','bonus_results','whatsapp_messages')
--   order by table_name, ordinal_position;
--
-- Expected (from schema.sql / bonus_status_schema.sql / whatsapp_schema.sql):
--   users:         id, name, level, whatsapp_number, is_active, created_at
--   reports:       id, file_name, file_path, status, uploaded_at
--   bonus_results: id, report_id, user_id, casino_pts, sport_pts,
--                  third_party_pts, profit_loss, ptype, bonus_amount,
--                  created_at, calculation_status
-- If a table is missing or a column differs, stop and tell the developer
-- before running the rest.
-- ---------------------------------------------------------------------------
--
-- What changes, in plain words:
--   1. users / reports / bonus_results get an `owner_id` column = the Supabase
--      Auth user (admin) who owns the row. The API now derives it from the
--      verified login token and filters EVERY query by it, so one admin can
--      never read or change another admin's data.
--      Existing rows keep owner_id = NULL ("legacy"): they are untouched but
--      not visible through the API until you claim them (see STEP 2 below).
--   2. bonus_results gains the calculation breakdown (personal adjustment,
--      referral adjustment, previous balance, final balance, payable bonus,
--      carry-forward) and WhatsApp "initiated" tracking.
--   3. reports gains small summary columns for the report-history list.
--   4. New tables: bonus_settings (3% / 10% rates), referral_entries,
--      calculation_history, whatsapp_initiations.
-- All new tables have Row Level Security enabled with no policies, exactly
-- like the existing tables: only the backend's service-role key can touch them.
-- =============================================================================

begin;

-- -----------------------------------------------------------------------------
-- 1. Ownership
-- -----------------------------------------------------------------------------
alter table public.users
    add column if not exists owner_id uuid references auth.users(id) on delete cascade;
alter table public.reports
    add column if not exists owner_id uuid references auth.users(id) on delete cascade;
alter table public.bonus_results
    add column if not exists owner_id uuid references auth.users(id) on delete cascade;

create index if not exists idx_users_owner_id on public.users(owner_id);
create index if not exists idx_reports_owner_uploaded on public.reports(owner_id, uploaded_at desc);
create index if not exists idx_bonus_results_owner_report on public.bonus_results(owner_id, report_id);

-- One casino user (matched by name, as the app always did) per admin account.
-- Partial index: legacy rows with owner_id NULL are not constrained.
create unique index if not exists users_owner_name_uidx
    on public.users(owner_id, name) where owner_id is not null;

-- -----------------------------------------------------------------------------
-- 2. Report summary (powers the report-history list without N+1 queries)
-- -----------------------------------------------------------------------------
alter table public.reports
    add column if not exists user_count integer,
    add column if not exists payable_user_count integer,
    add column if not exists total_payable numeric,
    add column if not exists calculated_at timestamptz;

-- -----------------------------------------------------------------------------
-- 3. Calculation breakdown + WhatsApp initiation on bonus_results
-- -----------------------------------------------------------------------------
-- `bonus_amount` (existing) now holds the FINAL PAYABLE bonus (never negative),
-- so everything that already reads bonus_amount keeps working.
alter table public.bonus_results
    add column if not exists personal_rate_used numeric,
    add column if not exists personal_adjustment numeric,
    add column if not exists referral_adjustment numeric,
    add column if not exists previous_balance numeric,
    add column if not exists final_balance numeric,
    add column if not exists payable_bonus numeric,
    add column if not exists carry_forward_balance numeric,
    add column if not exists calculated_at timestamptz,
    add column if not exists whatsapp_initiated_at timestamptz,
    add column if not exists whatsapp_initiated_count integer not null default 0;

-- -----------------------------------------------------------------------------
-- 4. Per-admin configurable rates
-- -----------------------------------------------------------------------------
create table if not exists public.bonus_settings (
    owner_id        uuid primary key references auth.users(id) on delete cascade,
    personal_rate   numeric not null default 0.03
                    constraint bonus_settings_personal_rate_check check (personal_rate >= 0 and personal_rate <= 1),
    referral_rate   numeric not null default 0.10
                    constraint bonus_settings_referral_rate_check check (referral_rate >= 0 and referral_rate <= 1),
    updated_at      timestamptz not null default now()
);

comment on table public.bonus_settings is
    'Per-admin bonus rates as fractions: personal_rate 0.03 = 3%, referral_rate 0.10 = 10%.';

-- -----------------------------------------------------------------------------
-- 5. Referral entries (one per referred user per period/report)
-- -----------------------------------------------------------------------------
create table if not exists public.referral_entries (
    id                uuid primary key default gen_random_uuid(),
    owner_id          uuid not null references auth.users(id) on delete cascade,
    report_id         uuid not null references public.reports(id) on delete cascade,
    referrer_user_id  uuid not null references public.users(id) on delete restrict,
    referred_user_id  uuid not null references public.users(id) on delete restrict,
    rate              numeric not null
                      constraint referral_entries_rate_check check (rate >= 0 and rate <= 1),
    -- Filled in when the report is calculated: the referred user's profit/loss
    -- for the period, and the resulting adjustment (+ for a loss, - for a win).
    amount            numeric,
    adjustment        numeric,
    calculated_at     timestamptz,
    created_at        timestamptz not null default now(),

    constraint referral_entries_not_self check (referrer_user_id <> referred_user_id),
    -- Duplicate / double-counting guard: a referred user's result can only
    -- feed ONE referrer in a given period.
    constraint referral_entries_one_referrer_per_period unique (owner_id, report_id, referred_user_id)
);

create index if not exists idx_referral_entries_owner_report on public.referral_entries(owner_id, report_id);
create index if not exists idx_referral_entries_referrer on public.referral_entries(referrer_user_id);

-- -----------------------------------------------------------------------------
-- 6. Calculation history (append-only: every run, including recalculations)
-- -----------------------------------------------------------------------------
create table if not exists public.calculation_history (
    id                     uuid primary key default gen_random_uuid(),
    owner_id               uuid not null references auth.users(id) on delete cascade,
    run_id                 uuid not null,
    report_id              uuid not null references public.reports(id) on delete cascade,
    bonus_result_id        uuid references public.bonus_results(id) on delete set null,
    user_id                uuid not null references public.users(id) on delete cascade,
    profit_loss            numeric not null,
    personal_rate          numeric not null,
    personal_adjustment    numeric not null,
    referral_adjustment    numeric not null,
    previous_balance       numeric not null,
    final_balance          numeric not null,
    payable_bonus          numeric not null,
    carry_forward_balance  numeric not null,
    calculated_at          timestamptz not null default now()
);

create index if not exists idx_calc_history_owner_user on public.calculation_history(owner_id, user_id, calculated_at desc);
create index if not exists idx_calc_history_owner_report on public.calculation_history(owner_id, report_id);

-- -----------------------------------------------------------------------------
-- 7. WhatsApp "opened" events (NOT delivery — the app only opens a wa.me link)
-- -----------------------------------------------------------------------------
create table if not exists public.whatsapp_initiations (
    id               uuid primary key default gen_random_uuid(),
    owner_id         uuid not null references auth.users(id) on delete cascade,
    bonus_result_id  uuid not null references public.bonus_results(id) on delete cascade,
    whatsapp_number  text not null,
    message_body     text not null,
    initiated_at     timestamptz not null default now()
);

comment on table public.whatsapp_initiations is
    'The admin opened WhatsApp with a pre-filled message. This is NOT proof the message was sent or delivered.';

create index if not exists idx_whatsapp_initiations_result on public.whatsapp_initiations(bonus_result_id);

-- -----------------------------------------------------------------------------
-- Row Level Security: enabled, no policies (service-role backend only)
-- -----------------------------------------------------------------------------
alter table public.bonus_settings enable row level security;
alter table public.referral_entries enable row level security;
alter table public.calculation_history enable row level security;
alter table public.whatsapp_initiations enable row level security;

commit;

-- =============================================================================
-- STEP 2 (optional, run separately): claim your EXISTING data
-- =============================================================================
-- Rows created before this migration have owner_id = NULL and are invisible to
-- the API. To make them yours, find your admin's id (Supabase -> Authentication
-- -> Users -> copy the UID) and run, replacing the placeholder:
--
--   update public.users         set owner_id = '<YOUR-ADMIN-UID>' where owner_id is null;
--   update public.reports       set owner_id = '<YOUR-ADMIN-UID>' where owner_id is null;
--   update public.bonus_results set owner_id = '<YOUR-ADMIN-UID>' where owner_id is null;
--
-- Do this for ONE admin only. If you have several admins, decide which one
-- owns the old data — it is not guessed for you. Do it BEFORE that admin
-- uploads any new report: otherwise a user name that now exists twice (once
-- legacy, once new) would violate users_owner_name_uidx and the update fails.
-- =============================================================================
