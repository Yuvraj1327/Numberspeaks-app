-- =============================================================================
-- Numberspeaks — Background report processing: status tracking on reports
-- =============================================================================
-- Run this once in the Supabase SQL Editor, after schema.sql. Purely
-- additive apart from widening the reports.status check constraint — no
-- existing row or column value is changed.
--
-- Upload now returns immediately and the report is processed in the
-- background, so the report row itself has to carry the progress:
--   status  uploaded -> processing (extracting) -> validating
--           -> calculating -> completed | failed
--   ('validated' is kept for the older manual /validate + /calculate-bonus
--    flow.)
-- =============================================================================

alter table public.reports drop constraint if exists reports_status_check;
alter table public.reports
    add constraint reports_status_check
    check (status in (
        'uploaded', 'processing', 'validating', 'calculating',
        'validated', 'completed', 'failed'
    ));

alter table public.reports
    add column if not exists error_message    text,
    add column if not exists pages_processed  integer not null default 0,
    add column if not exists total_records    integer not null default 0,
    add column if not exists calculated_count integer not null default 0,
    add column if not exists failed_count     integer not null default 0,
    add column if not exists warnings         jsonb   not null default '[]'::jsonb,
    -- Bumped on every claim of the report by a worker; used as a
    -- compare-and-swap token so two workers can never both process it.
    add column if not exists attempts         integer not null default 0,
    -- Bumped automatically (trigger below) on every update, so a report
    -- whose worker died stops changing and can be detected as abandoned.
    add column if not exists updated_at       timestamptz not null default now();

create or replace function public.reports_set_updated_at()
returns trigger
language plpgsql
as $$
begin
    new.updated_at = now();
    return new;
end;
$$;

drop trigger if exists trg_reports_set_updated_at on public.reports;
create trigger trg_reports_set_updated_at
    before update on public.reports
    for each row execute function public.reports_set_updated_at();

-- Status lookups for the abandoned-report check.
create index if not exists idx_reports_status on public.reports(status);
