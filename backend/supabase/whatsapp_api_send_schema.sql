-- =============================================================================
-- Numberspeaks — WhatsApp sending through the No1API backend integration
-- =============================================================================
-- Run once in the Supabase SQL Editor (additive, safe to re-run). Replaces the
-- "opened wa.me link" tracking; the older whatsapp_initiations table and
-- bonus_results.whatsapp_initiated_* columns are left in place, unused.
--
-- whatsapp_sends: one row per SEND ATTEMPT (full history, nothing overwritten).
-- The partial unique index below lets Postgres itself guarantee that a result
-- has at most ONE attempt that is 'sending' or 'sent' — two concurrent clicks
-- or a double-submit cannot both reach the provider. Only a 'failed' attempt
-- can be retried.
-- =============================================================================

begin;

create table if not exists public.whatsapp_sends (
    id                   uuid primary key default gen_random_uuid(),
    owner_id             uuid not null references auth.users(id) on delete cascade,
    bonus_result_id      uuid not null references public.bonus_results(id) on delete cascade,
    whatsapp_number      text not null,
    message_body         text not null,
    status               text not null default 'sending'
                         constraint whatsapp_sends_status_check
                         check (status in ('sending', 'sent', 'failed')),
    provider_message_id  text,
    error_message        text,
    created_at           timestamptz not null default now(),
    updated_at           timestamptz not null default now()
);

create unique index if not exists uq_whatsapp_sends_one_active
    on public.whatsapp_sends(bonus_result_id)
    where status in ('sending', 'sent');

create index if not exists idx_whatsapp_sends_owner_result
    on public.whatsapp_sends(owner_id, bonus_result_id, created_at desc);

-- Latest status, kept on the result row so the Results table needs no join.
alter table public.bonus_results
    add column if not exists whatsapp_send_status text not null default 'pending',
    add column if not exists whatsapp_send_error  text,
    add column if not exists whatsapp_sent_at     timestamptz;

do $$
begin
    if not exists (select 1 from pg_constraint where conname = 'bonus_results_whatsapp_send_status_check') then
        alter table public.bonus_results
            add constraint bonus_results_whatsapp_send_status_check
            check (whatsapp_send_status in ('pending', 'sending', 'sent', 'failed'));
    end if;
end $$;

-- Service-role backend only: RLS on, no policies.
alter table public.whatsapp_sends enable row level security;

commit;
