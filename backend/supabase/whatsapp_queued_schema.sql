-- =============================================================================
-- Numberspeaks — 'queued' status + provider queue id/status for No1API
-- =============================================================================
-- Run once AFTER whatsapp_bulk_schema.sql. Additive and safe to re-run.
--
-- No1API answers a send with {"message": {"queue_id": ..., "message_status": "queued"}}.
-- That means "accepted into No1API's queue" — not sent, not delivered. It is stored
-- as status 'queued' (queue id in provider_message_id, raw status in provider_status).
-- A queued message counts as active, so it cannot be sent twice.
-- =============================================================================

begin;

alter table public.whatsapp_sends add column if not exists provider_status text;

alter table public.whatsapp_sends drop constraint if exists whatsapp_sends_status_check;
alter table public.whatsapp_sends
    add constraint whatsapp_sends_status_check
    check (status in ('sending', 'queued', 'sent', 'failed', 'unknown'));

alter table public.bonus_results drop constraint if exists bonus_results_whatsapp_send_status_check;
alter table public.bonus_results
    add constraint bonus_results_whatsapp_send_status_check
    check (whatsapp_send_status in ('pending', 'sending', 'queued', 'sent', 'failed', 'unknown'));

alter table public.whatsapp_test_sends add column if not exists provider_status text;
alter table public.whatsapp_test_sends drop constraint if exists whatsapp_test_sends_status_check;
alter table public.whatsapp_test_sends
    add constraint whatsapp_test_sends_status_check check (status in ('queued', 'sent', 'failed', 'unknown'));

-- One ACTIVE attempt per result: sending, queued or sent.
drop index if exists public.uq_whatsapp_sends_one_active;
create unique index uq_whatsapp_sends_one_active
    on public.whatsapp_sends(bonus_result_id)
    where status in ('sending', 'queued', 'sent');

commit;
