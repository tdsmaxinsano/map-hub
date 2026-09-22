-- Map boot: years RPC — Disk IO follow-up, part 2 (pairs with migration 67)
-- ==========================================================================
-- Every map boot used to page `id + the 4 date columns` over EVERY row of
-- therapy_boss_completed_service_import_rows (the biggest table in the DB)
-- just to render the Service Years filter buttons. This replaces that third
-- full-table pass with one tiny server-side aggregate: ~10-20 ints instead
-- of the whole table over the wire. With migration 67's covering index
-- (idx_tbcs_rows_year_cover INCLUDEs all 4 dates) the planner can answer it
-- from an index-only scan without touching the heap.
--
-- The client (clinician-map.html) calls this RPC-first and falls back to
-- the legacy full pass if the RPC is missing — so deploy order is flexible,
-- but the Disk IO win only lands once this has been run.
--
-- Year derivation mirrors the client's getCompletedServiceRowYear():
--   first non-empty of last_visit_date → ended_date → start_of_episode →
--   referral_date (JS `||` treats '' as missing → NULLIF), floored at 2000
--   so a residual corrupt date (e.g. a 1905 row from a pre-#131 import)
--   can't render a bogus year button.
-- Type-agnostic like the migration-43 repair: each column is cast to text
-- and the year is only parsed behind a regex guard (CASE evaluates the
-- guard before the cast), so a malformed value can't error the whole call.
--
-- Idempotent — CREATE OR REPLACE. Safe to re-run.

BEGIN;

CREATE OR REPLACE FUNCTION public.list_completed_service_years()
RETURNS TABLE (service_year INTEGER)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $fn$
  SELECT DISTINCT years.service_year
  FROM (
    SELECT CASE
             WHEN row_dates.reference_date ~ '^\d{4}'
             THEN LEFT(row_dates.reference_date, 4)::INTEGER
           END AS service_year
    FROM (
      SELECT COALESCE(
               NULLIF(TRIM(last_visit_date::text), ''),
               NULLIF(TRIM(ended_date::text), ''),
               NULLIF(TRIM(start_of_episode::text), ''),
               NULLIF(TRIM(referral_date::text), '')
             ) AS reference_date
      FROM public.therapy_boss_completed_service_import_rows
    ) AS row_dates
  ) AS years
  WHERE years.service_year IS NOT NULL
    AND years.service_year >= 2000
  ORDER BY years.service_year DESC;
$fn$;

REVOKE ALL ON FUNCTION public.list_completed_service_years() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.list_completed_service_years() TO authenticated;

NOTIFY pgrst, 'reload schema';

COMMIT;
