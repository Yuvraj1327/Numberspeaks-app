-- =============================================================================
-- Numberspeaks — weekly periods, referrers, manual referral amounts, WhatsApp template
-- =============================================================================
-- Run in the Supabase SQL Editor AFTER multi_tenant_bonus_schema.sql.
-- ADDITIVE ONLY and safe to re-run: nothing is dropped, renamed or rewritten,
-- existing reports simply keep period_start/period_end = NULL ("legacy").
begin;

-- 1. Weekly period per report; one report per exact period per admin.
alter table public.reports
    add column if not exists period_start date,
    add column if not exists period_end   date;

do $$ begin
    alter table public.reports add constraint reports_period_order_check
        check (period_start is null or period_end is null or period_end >= period_start);
exception when duplicate_object then null; end $$;

create unique index if not exists reports_owner_period_uidx
    on public.reports(owner_id, period_start, period_end)
    where period_start is not null and period_end is not null;

-- 2. Manual loss/win amount (+ note) on a referral entry.
alter table public.referral_entries
    add column if not exists manual_amount numeric,
    add column if not exists note text;

-- 3. Persistent referrer details (one per user per admin).
create table if not exists public.referrers (
    id            uuid primary key default gen_random_uuid(),
    owner_id      uuid not null references auth.users(id) on delete cascade,
    user_id       uuid not null references public.users(id) on delete cascade,
    display_name  text,
    notes         text,
    default_rate  numeric
                  constraint referrers_default_rate_check check (default_rate is null or (default_rate >= 0 and default_rate <= 1)),
    is_active     boolean not null default true,
    created_at    timestamptz not null default now(),
    constraint referrers_owner_user_unique unique (owner_id, user_id)
);
create index if not exists idx_referrers_owner on public.referrers(owner_id);
alter table public.referrers enable row level security;

-- 4. Editable WhatsApp message template (NULL = built-in default).
alter table public.bonus_settings
    add column if not exists whatsapp_template text;

commit;
