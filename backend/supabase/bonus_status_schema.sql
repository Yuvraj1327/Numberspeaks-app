-- =============================================================================
-- Numberspeaks — Actual Bonus Feature: calculation_status on bonus_results
-- =============================================================================
-- Run this once in the Supabase SQL Editor, after schema.sql (and
-- whatsapp_schema.sql, if not already applied). Purely additive — no
-- existing column or row is changed; existing rows get the default value.
--
-- Why this is needed: the real bonus formula always returns a number
-- (₹0 for a non-loss row is a valid, successfully-calculated result, not
-- a missing one), so `bonus_amount is null` can no longer be used to tell
-- "not yet calculated" apart from "row failed validation". This column
-- makes that distinction explicit and durable, per the spec's requirement
-- to save a "Calculation status" and to never silently drop invalid rows.
-- =============================================================================

alter table public.bonus_results
    add column if not exists calculation_status text not null default 'pending';

do $$
begin
    if not exists (
        select 1 from pg_constraint where conname = 'bonus_results_calculation_status_check'
    ) then
        alter table public.bonus_results
            add constraint bonus_results_calculation_status_check
            check (calculation_status in ('pending', 'calculated', 'invalid'));
    end if;
end $$;

comment on column public.bonus_results.calculation_status is
    'pending = not yet calculated, calculated = formula applied (bonus_amount may legitimately be 0), invalid = row failed validation and was never calculated.';
