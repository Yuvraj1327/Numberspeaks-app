-- =============================================================================
-- Numberspeaks — Step 7: WhatsApp message tracking
-- =============================================================================
-- Run this once in the Supabase SQL Editor, after schema.sql. Purely
-- additive — no existing table is changed.
--
-- One row per SEND ATTEMPT (not per bonus_result), so re-sends (when
-- explicitly requested) keep full history instead of overwriting the last
-- attempt. Whether a bonus result has already been successfully notified
-- is answered by querying for a 'sent' row, not by a flag on bonus_results.
-- =============================================================================

create table if not exists public.whatsapp_messages (
    id                    uuid primary key default gen_random_uuid(),
    bonus_result_id       uuid not null references public.bonus_results(id) on delete cascade,
    whatsapp_number       text not null,
    message_body          text not null,
    status                text not null default 'pending'
                          constraint whatsapp_messages_status_check
                          check (status in ('pending', 'sent', 'failed')),
    provider_message_id   text,
    error_message         text,
    sent_at               timestamptz,
    created_at            timestamptz not null default now()
);

comment on table public.whatsapp_messages is
    'One row per WhatsApp send attempt for a bonus_results row. Used for success/failure status and to avoid accidental re-sends.';

create index if not exists idx_whatsapp_messages_bonus_result_id on public.whatsapp_messages(bonus_result_id);
create index if not exists idx_whatsapp_messages_status on public.whatsapp_messages(status);

alter table public.whatsapp_messages enable row level security;
