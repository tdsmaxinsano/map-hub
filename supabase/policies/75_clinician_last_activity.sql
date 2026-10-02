-- ════════════════════════════════════════════════════════════════════
-- 75 · list_clinician_last_activity() — "who hasn't had visits lately"
--
-- Per clinician: the LATEST plausible completed-service date, computed
-- exactly like the Map profile's ⚠ inactive flag (max across
-- start_of_episode / referral_date / last_visit_date / ended_date),
-- type-agnostic (text cast + YYYY-MM-DD regex guard, same approach as
-- migrations 43/68), floored at 2000-01-01 and capped at CURRENT_DATE
-- so a typo'd future date can't mark someone active forever.
--
-- Drives the Roster Review "Last Visit" column + Quiet 30/60/90d+
-- filters. SECURITY DEFINER, authenticated (same posture as
-- list_clinician_visit_summary). Idempotent.
-- ════════════════════════════════════════════════════════════════════
BEGIN;

CREATE OR REPLACE FUNCTION public.list_clinician_last_activity()
RETURNS TABLE (clinician_id UUID, last_activity DATE)
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT c.matched_clinician_id AS clinician_id,
         MAX(substring(v.dtxt FROM 1 FOR 10)::date) AS last_activity
  FROM public.therapy_boss_completed_service_import_clinicians c
  JOIN public.therapy_boss_completed_service_import_rows r
    ON r.id = c.service_row_id
  CROSS JOIN LATERAL (VALUES
    (r.start_of_episode::text),
    (r.referral_date::text),
    (r.last_visit_date::text),
    (r.ended_date::text)
  ) AS v(dtxt)
  WHERE c.matched_clinician_id IS NOT NULL
    AND v.dtxt ~ '^\d{4}-\d{2}-\d{2}'
    AND substring(v.dtxt FROM 1 FOR 10)::date
        BETWEEN DATE '2000-01-01' AND CURRENT_DATE
  GROUP BY c.matched_clinician_id
$$;

GRANT EXECUTE ON FUNCTION public.list_clinician_last_activity() TO authenticated;

NOTIFY pgrst, 'reload schema';

COMMIT;
