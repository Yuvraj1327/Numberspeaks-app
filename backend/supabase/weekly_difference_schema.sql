-- =============================================================================
-- Numberspeaks — weekly difference (cumulative report totals)
-- =============================================================================
-- Run in the Supabase SQL Editor AFTER period_referrers_schema.sql.
-- ADDITIVE ONLY and safe to re-run: nothing is dropped, renamed or rewritten.
-- Weeks calculated before this change keep NULL in the new columns ("legacy")
-- and their stored figures are never touched.
begin;

alter table public.bonus_results
    add column if not exists previous_report_total numeric,  -- user's cumulative total in the previous report (0 if none)
    add column if not exists current_report_total  numeric,  -- this report's cumulative total (= profit_loss)
    add column if not exists weekly_change         numeric,  -- current - previous: this week's actual win/loss
    add column if not exists bonus_basis           numeric;  -- amount the personal % was applied to

alter table public.calculation_history
    add column if not exists previous_report_total numeric,
    add column if not exists weekly_change         numeric;

commit;
