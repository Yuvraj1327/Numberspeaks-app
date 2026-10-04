-- Numberspeaks — lets a signed-in account delete ITS OWN saved copy of a
-- report (the ns_* rows and the PDF in the report-pdfs bucket) when it
-- deletes the report in the app. Run once in the Supabase SQL editor, after
-- numberspeaks_results_schema.sql. Without it the app's delete still works;
-- only this saved copy is left behind.

drop policy if exists "Owner can delete own reports" on public.ns_reports;
drop policy if exists "Owner can delete own results" on public.ns_bonus_results;
drop policy if exists "Owner can delete own report PDFs" on storage.objects;

create policy "Owner can delete own reports" on public.ns_reports
  for delete using (owner_id = auth.uid());

create policy "Owner can delete own results" on public.ns_bonus_results
  for delete using (owner_id = auth.uid());

create policy "Owner can delete own report PDFs" on storage.objects
  for delete using (
    bucket_id = 'report-pdfs'
    and (storage.foldername(name))[1] = auth.uid()::text
  );
