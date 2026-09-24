-- =============================================================================
-- Numberspeaks — Step 3: Storage bucket for uploaded PDF reports
-- =============================================================================
-- Run this once in the Supabase SQL Editor, after schema.sql.
--
-- Creates a private bucket named 'reports'. Uploaded PDFs are stored at
-- "<report_id>/<original_file_name>.pdf" inside it. The bucket is private
-- (public = false) — only the backend's service-role key can read/write
-- it, the same trust model as the database tables.
--
-- Equivalent to creating the bucket via Supabase Dashboard -> Storage ->
-- New bucket (name: reports, Public: off) — use whichever is convenient.
-- =============================================================================

insert into storage.buckets (id, name, public)
values ('reports', 'reports', false)
on conflict (id) do nothing;
