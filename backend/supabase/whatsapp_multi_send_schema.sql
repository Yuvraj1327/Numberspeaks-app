-- =============================================================================
-- Numberspeaks — allow several messages to the same recipient
-- =============================================================================
-- Run once AFTER whatsapp_queued_schema.sql. Safe to re-run.
--
-- Only an in-flight ('sending') attempt is unique per result now. Queued, sent,
-- failed and unknown attempts are history, so an intentional new message to the
-- same number is never blocked by an earlier one.
-- =============================================================================

begin;

drop index if exists public.uq_whatsapp_sends_one_active;
create unique index uq_whatsapp_sends_one_active
    on public.whatsapp_sends(bonus_result_id)
    where status = 'sending';

commit;
