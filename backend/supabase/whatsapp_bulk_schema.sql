-- =============================================================================
-- Numberspeaks — WhatsApp bulk sending, attempt audit fields, 'unknown' status
-- =============================================================================
-- Run once AFTER whatsapp_api_send_schema.sql. Additive and safe to re-run.
-- =============================================================================

begin;

-- Every attempt records report/week, user, recipient, message, time, provider id, status.
alter table public.whatsapp_sends
    add column if not exists report_id uuid references public.reports(id) on delete set null,
    add column if not exists user_id   uuid references public.users(id)   on delete set null,
    add column if not exists batch_id  uuid;

-- 'unknown' = the request may have reached the provider but its outcome was never
-- recorded. It is NOT retried automatically; the admin retries explicitly.
alter table public.whatsapp_sends drop constraint if exists whatsapp_sends_status_check;
alter table public.whatsapp_sends
    add constraint whatsapp_sends_status_check check (status in ('sending', 'sent', 'failed', 'unknown'));

alter table public.bonus_results drop constraint if exists bonus_results_whatsapp_send_status_check;
alter table public.bonus_results
    add constraint bonus_results_whatsapp_send_status_check
    check (whatsapp_send_status in ('pending', 'sending', 'sent', 'failed', 'unknown'));

create index if not exists idx_whatsapp_sends_batch on public.whatsapp_sends(batch_id);

-- One row per bulk run. Progress = this row + the whatsapp_sends rows with its batch_id.
create table if not exists public.whatsapp_batches (
    id            uuid primary key default gen_random_uuid(),
    owner_id      uuid not null references auth.users(id) on delete cascade,
    report_id     uuid not null references public.reports(id) on delete cascade,
    status        text not null default 'running' check (status in ('running', 'completed')),
    total_queued  integer not null default 0,
    skipped       jsonb not null default '[]'::jsonb,
    created_at    timestamptz not null default now(),
    updated_at    timestamptz not null default now(),
    finished_at   timestamptz
);
create index if not exists idx_whatsapp_batches_owner on public.whatsapp_batches(owner_id, created_at desc);

-- A bulk run is only allowed after one message to an authorized test number was
-- accepted by the provider (so credentials/format are proven before real users).
create table if not exists public.whatsapp_test_sends (
    id                   uuid primary key default gen_random_uuid(),
    owner_id             uuid not null references auth.users(id) on delete cascade,
    whatsapp_number      text not null,
    message_body         text not null,
    status               text not null check (status in ('sent', 'failed', 'unknown')),
    provider_message_id  text,
    error_message        text,
    created_at           timestamptz not null default now()
);
create index if not exists idx_whatsapp_test_sends_owner on public.whatsapp_test_sends(owner_id, created_at desc);

alter table public.whatsapp_batches enable row level security;
alter table public.whatsapp_test_sends enable row level security;

commit;
