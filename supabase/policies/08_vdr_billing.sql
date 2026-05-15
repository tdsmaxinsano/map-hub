-- VDR (Visit Discrepancy Report) + per-clinician + per-payer billing metrics
-- =====================================================================
-- Replaces the user's two local Python scripts:
--   1. Processed_VDR.py runner (Create bills export → flagged-discrepancies XLSX)
--   2. Processed_VDR.py aggregator (folder of VDR files → cumulative trends)
--
-- All processing is now browser-side in finance.html. This SQL gives us:
--   * vdr_runs — one row per run (totals + discrepancy counts + storage pointer)
--   * vdr_clinician_metrics — per-run, per-clinician aggregates for grading
--   * vdr_payer_metrics — per-run, per-payer revenue for trend charts
--   * vdr-reports storage bucket — generated XLSX files (private, admin-only)
--   * RLS — admin-only across the board (Finance area is already admin-gated)
--
-- Idempotent — safe to re-run.

BEGIN;

-- ── Tables ─────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.vdr_runs (
  id                       UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  ran_at                   TIMESTAMPTZ NOT NULL DEFAULT now(),
  ran_by                   UUID NOT NULL DEFAULT auth.uid(),
  total_visits             INTEGER NOT NULL,
  total_charges            NUMERIC(12,2) NOT NULL,
  out_of_range_count       INTEGER NOT NULL DEFAULT 0,
  short_billable_count     INTEGER NOT NULL DEFAULT 0,
  missed_visit_count       INTEGER NOT NULL DEFAULT 0,
  eval_time_alert_count    INTEGER NOT NULL DEFAULT 0,
  both_conditions_count    INTEGER NOT NULL DEFAULT 0,
  visit_date_min           DATE,
  visit_date_max           DATE,
  report_path              TEXT,
  source_filename          TEXT,
  -- Compact JSON snapshot of every prepared row (with derived flag booleans)
  -- so the Billing page can instantly rebuild the inline preview (charts +
  -- discrepancy tables) when an admin clicks "View" on a history row,
  -- without re-downloading + re-parsing the archived XLSX.
  prepared_rows            JSONB NOT NULL DEFAULT '[]'::jsonb,
  extras                   JSONB NOT NULL DEFAULT '{}'::jsonb,
  notes                    TEXT
);
CREATE INDEX IF NOT EXISTS vdr_runs_ran_at_idx ON public.vdr_runs (ran_at DESC);

-- If table already exists from a prior partial run, ensure the new column is added
ALTER TABLE public.vdr_runs ADD COLUMN IF NOT EXISTS prepared_rows JSONB NOT NULL DEFAULT '[]'::jsonb;

CREATE TABLE IF NOT EXISTS public.vdr_clinician_metrics (
  id                       UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  vdr_run_id               UUID NOT NULL REFERENCES public.vdr_runs(id) ON DELETE CASCADE,
  clinician_name           TEXT NOT NULL,
  clinician_id             UUID,
  visit_count              INTEGER NOT NULL DEFAULT 0,
  avg_days_to_submit       NUMERIC(8,2),
  avg_visit_minutes        NUMERIC(8,2),
  charge_total             NUMERIC(12,2) NOT NULL DEFAULT 0,
  out_of_range_count       INTEGER NOT NULL DEFAULT 0,
  short_billable_count     INTEGER NOT NULL DEFAULT 0,
  missed_visit_count       INTEGER NOT NULL DEFAULT 0,
  eval_time_alert_count    INTEGER NOT NULL DEFAULT 0,
  extras                   JSONB NOT NULL DEFAULT '{}'::jsonb
);
CREATE INDEX IF NOT EXISTS vdr_clinician_metrics_run_idx       ON public.vdr_clinician_metrics (vdr_run_id);
CREATE INDEX IF NOT EXISTS vdr_clinician_metrics_clinician_idx ON public.vdr_clinician_metrics (clinician_id);
CREATE INDEX IF NOT EXISTS vdr_clinician_metrics_name_idx      ON public.vdr_clinician_metrics (clinician_name);

-- If table already existed before avg_visit_minutes was added, patch it now
ALTER TABLE public.vdr_clinician_metrics ADD COLUMN IF NOT EXISTS avg_visit_minutes NUMERIC(8,2);

-- Backfill avg_visit_minutes for already-saved runs that have a prepared_rows
-- JSONB snapshot. Idempotent — only updates rows where avg_visit_minutes is
-- still NULL. Runs saved before prepared_rows existed simply skip (column
-- stays NULL; user can re-save the run if they need it backfilled).
UPDATE public.vdr_clinician_metrics m
SET avg_visit_minutes = sub.avg_minutes
FROM (
  SELECT
    vr.id                       AS run_id,
    TRIM(elem->>'Clinician')    AS clin_name,
    ROUND(AVG((elem->>'Time')::numeric), 2) AS avg_minutes
  FROM public.vdr_runs vr
  CROSS JOIN LATERAL jsonb_array_elements(COALESCE(vr.prepared_rows, '[]'::jsonb)) AS elem
  WHERE elem ? 'Time'
    AND elem ? 'Clinician'
    AND (elem->>'Time') ~ '^-?[0-9]+(\.[0-9]+)?$'
  GROUP BY vr.id, TRIM(elem->>'Clinician')
) sub
WHERE m.vdr_run_id = sub.run_id
  AND m.clinician_name = sub.clin_name
  AND m.avg_visit_minutes IS NULL;

CREATE TABLE IF NOT EXISTS public.vdr_payer_metrics (
  id                       UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  vdr_run_id               UUID NOT NULL REFERENCES public.vdr_runs(id) ON DELETE CASCADE,
  payer_name               TEXT NOT NULL,
  visit_count              INTEGER NOT NULL DEFAULT 0,
  charge_total             NUMERIC(12,2) NOT NULL DEFAULT 0,
  extras                   JSONB NOT NULL DEFAULT '{}'::jsonb
);
CREATE INDEX IF NOT EXISTS vdr_payer_metrics_run_idx ON public.vdr_payer_metrics (vdr_run_id);

-- ── RLS — admin-only ───────────────────────────────────────────────
ALTER TABLE public.vdr_runs              ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.vdr_clinician_metrics ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.vdr_payer_metrics     ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "vdr_runs_admin_all" ON public.vdr_runs;
CREATE POLICY "vdr_runs_admin_all" ON public.vdr_runs
  FOR ALL TO authenticated
  USING     (EXISTS (SELECT 1 FROM public.user_roles WHERE user_id = auth.uid() AND role = 'admin'))
  WITH CHECK (EXISTS (SELECT 1 FROM public.user_roles WHERE user_id = auth.uid() AND role = 'admin'));

DROP POLICY IF EXISTS "vdr_clinician_metrics_admin_all" ON public.vdr_clinician_metrics;
CREATE POLICY "vdr_clinician_metrics_admin_all" ON public.vdr_clinician_metrics
  FOR ALL TO authenticated
  USING     (EXISTS (SELECT 1 FROM public.user_roles WHERE user_id = auth.uid() AND role = 'admin'))
  WITH CHECK (EXISTS (SELECT 1 FROM public.user_roles WHERE user_id = auth.uid() AND role = 'admin'));

DROP POLICY IF EXISTS "vdr_payer_metrics_admin_all" ON public.vdr_payer_metrics;
CREATE POLICY "vdr_payer_metrics_admin_all" ON public.vdr_payer_metrics
  FOR ALL TO authenticated
  USING     (EXISTS (SELECT 1 FROM public.user_roles WHERE user_id = auth.uid() AND role = 'admin'))
  WITH CHECK (EXISTS (SELECT 1 FROM public.user_roles WHERE user_id = auth.uid() AND role = 'admin'));

-- ── Storage bucket: vdr-reports (private, admin-only) ───────────
INSERT INTO storage.buckets (id, name, public)
VALUES ('vdr-reports', 'vdr-reports', false)
ON CONFLICT (id) DO NOTHING;

DROP POLICY IF EXISTS "vdr_reports_admin_read"  ON storage.objects;
DROP POLICY IF EXISTS "vdr_reports_admin_write" ON storage.objects;

CREATE POLICY "vdr_reports_admin_read" ON storage.objects
  FOR SELECT TO authenticated
  USING (bucket_id = 'vdr-reports'
         AND EXISTS (SELECT 1 FROM public.user_roles WHERE user_id = auth.uid() AND role = 'admin'));

CREATE POLICY "vdr_reports_admin_write" ON storage.objects
  FOR ALL TO authenticated
  USING (bucket_id = 'vdr-reports'
         AND EXISTS (SELECT 1 FROM public.user_roles WHERE user_id = auth.uid() AND role = 'admin'))
  WITH CHECK (bucket_id = 'vdr-reports'
              AND EXISTS (SELECT 1 FROM public.user_roles WHERE user_id = auth.uid() AND role = 'admin'));

COMMIT;
