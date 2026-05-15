-- Aggregated per-clinician VDR metrics — RPC for both Roster Review + Map
-- =====================================================================
-- Rolls up every saved row in vdr_clinician_metrics into one row per
-- clinician (by id) + one row per unmatched clinician_name. Returns:
--   * run_count            — how many VDR runs include this clinician
--   * total_visits         — sum across all runs
--   * avg_visits_per_run   — total_visits / run_count
--   * avg_sync_days        — visit-weighted average of avg_days_to_submit
--   * total_charges        — sum across all runs
--   * latest_run_at        — most recent vdr_runs.ran_at they appear in
--
-- SECURITY DEFINER: the underlying tables are admin-only via RLS, but
-- these AGGREGATE numbers are safe to expose to editors (Roster Review
-- is editor-accessible). Granular per-run rows + raw exports remain
-- gated by their existing admin-only policies.

BEGIN;

-- Self-healing: ensure avg_visit_minutes exists before the function below
-- references it. Idempotent — no-op if the column is already there.
-- (Normally added by migration 08 — this guard means 09 can be re-run
-- without an "ordering" gotcha if 08 wasn't applied first.)
ALTER TABLE public.vdr_clinician_metrics
  ADD COLUMN IF NOT EXISTS avg_visit_minutes NUMERIC(8,2);

CREATE OR REPLACE FUNCTION public.list_clinician_vdr_summary()
RETURNS TABLE(
  clinician_id        UUID,
  clinician_name      TEXT,
  run_count           INTEGER,
  total_visits        INTEGER,
  avg_visits_per_run  NUMERIC,
  avg_sync_days       NUMERIC,
  avg_visit_minutes   NUMERIC,
  total_charges       NUMERIC,
  latest_run_at       TIMESTAMPTZ
)
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT
    m.clinician_id,
    (ARRAY_AGG(m.clinician_name ORDER BY r.ran_at DESC))[1]            AS clinician_name,
    COUNT(*)::INTEGER                                                  AS run_count,
    SUM(m.visit_count)::INTEGER                                        AS total_visits,
    ROUND(SUM(m.visit_count)::NUMERIC / NULLIF(COUNT(*), 0), 1)        AS avg_visits_per_run,
    ROUND(
      SUM(m.avg_days_to_submit * m.visit_count)
      / NULLIF(SUM(m.visit_count), 0),
      1
    )                                                                   AS avg_sync_days,
    -- Visit-weighted average visit duration in minutes; NULL when no runs
    -- contributed a value (older saves before this column existed).
    ROUND(
      SUM(m.avg_visit_minutes * m.visit_count)
      FILTER (WHERE m.avg_visit_minutes IS NOT NULL)
      / NULLIF(SUM(m.visit_count) FILTER (WHERE m.avg_visit_minutes IS NOT NULL), 0),
      1
    )                                                                   AS avg_visit_minutes,
    SUM(m.charge_total)                                                AS total_charges,
    MAX(r.ran_at)                                                      AS latest_run_at
  FROM public.vdr_clinician_metrics m
  JOIN public.vdr_runs r ON r.id = m.vdr_run_id
  WHERE m.visit_count > 0
  GROUP BY m.clinician_id, m.clinician_name;
$$;

REVOKE ALL ON FUNCTION public.list_clinician_vdr_summary() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.list_clinician_vdr_summary() TO authenticated;

COMMIT;
