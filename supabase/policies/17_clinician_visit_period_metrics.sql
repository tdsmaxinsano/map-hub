-- Clinician per-pay-period visit metrics — derived from TB Patient Visits
-- =====================================================================
-- The Roster Review page already shows three per-clinician aggregates:
--   * AVG SYNC DAYS   (from completion_delay → days)
--   * AVG VISITS/RUN  (from per-period count, where "run" = pay period)
--   * AVG VISIT TIME  (from duration_minutes)
--
-- Until now these came from VDR (Create-bills exports). VDR captures
-- BILLABLE visits only and depends on the admin running the VDR Runner.
-- Patient Visits is the canonical source — every visit, with explicit
-- completion delay + duration per row. This migration adds a per-period
-- aggregation table populated by the existing Eval Compliance Patient
-- Visits import (one import → two consumers).
--
-- Pay period: bi-weekly, Thursday-anchored at 2024-10-17 (matches the
-- time-tracker / payroll cycle described in CLAUDE.md).
--
-- Idempotent — safe to re-run.

BEGIN;

CREATE TABLE IF NOT EXISTS public.clinician_visit_period_metrics (
  id                       UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  clinician_name           TEXT NOT NULL,
  clinician_id             UUID,                       -- resolved against clinician_v2 (nullable)
  pay_period_start         DATE NOT NULL,
  pay_period_end           DATE NOT NULL,
  visit_count              INTEGER NOT NULL DEFAULT 0,
  eval_count               INTEGER NOT NULL DEFAULT 0, -- subset: PTE/OTE/STE/PTRE/OTRE/STRE
  billable_count           INTEGER NOT NULL DEFAULT 0,
  payable_count            INTEGER NOT NULL DEFAULT 0,
  total_duration_minutes   NUMERIC(10,2) NOT NULL DEFAULT 0,
  avg_duration_minutes     NUMERIC(8,2),               -- total_duration / visit_count
  total_completion_hours   NUMERIC(10,2),              -- sum of parsed "X d Y h Z m"
  avg_completion_hours     NUMERIC(8,2),
  avg_sync_days            NUMERIC(8,2),               -- avg_completion_hours / 24
  imported_at              TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (clinician_name, pay_period_start)
);

CREATE INDEX IF NOT EXISTS idx_cvpm_clinician_id   ON public.clinician_visit_period_metrics (clinician_id);
CREATE INDEX IF NOT EXISTS idx_cvpm_clinician_name ON public.clinician_visit_period_metrics (clinician_name);
CREATE INDEX IF NOT EXISTS idx_cvpm_period         ON public.clinician_visit_period_metrics (pay_period_start DESC);

-- RLS: admin + editor write, all authenticated can read aggregates
ALTER TABLE public.clinician_visit_period_metrics ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "cvpm_select_auth"        ON public.clinician_visit_period_metrics;
DROP POLICY IF EXISTS "cvpm_write_editor_admin" ON public.clinician_visit_period_metrics;

CREATE POLICY "cvpm_select_auth" ON public.clinician_visit_period_metrics
  FOR SELECT TO authenticated USING (true);

CREATE POLICY "cvpm_write_editor_admin" ON public.clinician_visit_period_metrics
  FOR ALL TO authenticated
  USING      (EXISTS (SELECT 1 FROM public.user_roles ur
                      WHERE ur.user_id = auth.uid() AND ur.role IN ('admin','editor')))
  WITH CHECK (EXISTS (SELECT 1 FROM public.user_roles ur
                      WHERE ur.user_id = auth.uid() AND ur.role IN ('admin','editor')));

-- ── RPC: bulk upsert per-(clinician, pay_period) aggregates ───────
CREATE OR REPLACE FUNCTION public.upsert_clinician_visit_periods(rows jsonb)
RETURNS INTEGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE n INT;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM user_roles ur
                 WHERE ur.user_id = auth.uid() AND ur.role IN ('admin','editor')) THEN
    RAISE EXCEPTION 'Only admin/editor may upsert clinician visit metrics';
  END IF;

  WITH src AS (
    SELECT x.*, row_number() OVER () AS rn
    FROM jsonb_to_recordset(rows) AS x(
      clinician_name         TEXT,
      pay_period_start       DATE,
      pay_period_end         DATE,
      visit_count            INTEGER,
      eval_count             INTEGER,
      billable_count         INTEGER,
      payable_count          INTEGER,
      total_duration_minutes NUMERIC,
      avg_duration_minutes   NUMERIC,
      total_completion_hours NUMERIC,
      avg_completion_hours   NUMERIC,
      avg_sync_days          NUMERIC
    )
  ),
  -- Defensive dedupe in case the payload has duplicates
  src_dedup AS (
    SELECT DISTINCT ON (clinician_name, pay_period_start)
           clinician_name, pay_period_start, pay_period_end,
           visit_count, eval_count, billable_count, payable_count,
           total_duration_minutes, avg_duration_minutes,
           total_completion_hours, avg_completion_hours, avg_sync_days
    FROM src
    WHERE clinician_name IS NOT NULL AND TRIM(clinician_name) <> ''
      AND pay_period_start IS NOT NULL
    ORDER BY clinician_name, pay_period_start, rn DESC
  ),
  ins AS (
    INSERT INTO clinician_visit_period_metrics
      (clinician_name, pay_period_start, pay_period_end,
       visit_count, eval_count, billable_count, payable_count,
       total_duration_minutes, avg_duration_minutes,
       total_completion_hours, avg_completion_hours, avg_sync_days,
       imported_at)
    SELECT clinician_name, pay_period_start, pay_period_end,
           visit_count, eval_count, billable_count, payable_count,
           total_duration_minutes, avg_duration_minutes,
           total_completion_hours, avg_completion_hours, avg_sync_days,
           now()
    FROM src_dedup
    ON CONFLICT (clinician_name, pay_period_start) DO UPDATE
      SET pay_period_end         = EXCLUDED.pay_period_end,
          visit_count            = EXCLUDED.visit_count,
          eval_count             = EXCLUDED.eval_count,
          billable_count         = EXCLUDED.billable_count,
          payable_count          = EXCLUDED.payable_count,
          total_duration_minutes = EXCLUDED.total_duration_minutes,
          avg_duration_minutes   = EXCLUDED.avg_duration_minutes,
          total_completion_hours = EXCLUDED.total_completion_hours,
          avg_completion_hours   = EXCLUDED.avg_completion_hours,
          avg_sync_days          = EXCLUDED.avg_sync_days,
          imported_at            = now()
    RETURNING 1
  )
  SELECT count(*) INTO n FROM ins;

  -- Best-effort clinician_id resolution against clinician_v2 by normalized name.
  -- (Editor+admin can already write to clinician_v2, so this UPDATE is safe.)
  UPDATE clinician_visit_period_metrics m
  SET clinician_id = v.id
  FROM clinician_v2 v
  WHERE m.clinician_id IS NULL
    AND LOWER(REGEXP_REPLACE(m.clinician_name, '\s+', ' ', 'g')) =
        LOWER(REGEXP_REPLACE(v.name,            '\s+', ' ', 'g'));

  RETURN n;
END $$;

-- ── RPC: per-clinician summary across all periods ─────────────────
-- Same shape as list_clinician_vdr_summary so Roster can swap sources
-- with minimal code change. Fields kept name-compatible.
CREATE OR REPLACE FUNCTION public.list_clinician_visit_summary()
RETURNS TABLE(
  clinician_id        UUID,
  clinician_name      TEXT,
  run_count           INTEGER,    -- # of distinct pay periods this clinician appears in
  total_visits        INTEGER,
  avg_visits_per_run  NUMERIC,    -- total_visits / run_count
  avg_sync_days       NUMERIC,    -- visit-weighted avg of avg_sync_days
  avg_visit_minutes   NUMERIC,    -- visit-weighted avg of avg_duration_minutes
  total_eval_visits   INTEGER,
  latest_period_start DATE,
  latest_period_end   DATE
)
LANGUAGE sql SECURITY DEFINER SET search_path = public AS $$
  SELECT
    m.clinician_id,
    (ARRAY_AGG(m.clinician_name ORDER BY m.pay_period_start DESC))[1]   AS clinician_name,
    COUNT(*)::INTEGER                                                   AS run_count,
    SUM(m.visit_count)::INTEGER                                         AS total_visits,
    ROUND(SUM(m.visit_count)::NUMERIC / NULLIF(COUNT(*), 0), 1)         AS avg_visits_per_run,
    ROUND(
      SUM(m.avg_sync_days * m.visit_count)
        FILTER (WHERE m.avg_sync_days IS NOT NULL)
      / NULLIF(SUM(m.visit_count) FILTER (WHERE m.avg_sync_days IS NOT NULL), 0),
      1
    )                                                                    AS avg_sync_days,
    ROUND(
      SUM(m.avg_duration_minutes * m.visit_count)
        FILTER (WHERE m.avg_duration_minutes IS NOT NULL)
      / NULLIF(SUM(m.visit_count) FILTER (WHERE m.avg_duration_minutes IS NOT NULL), 0),
      1
    )                                                                    AS avg_visit_minutes,
    SUM(m.eval_count)::INTEGER                                          AS total_eval_visits,
    MAX(m.pay_period_start)                                             AS latest_period_start,
    MAX(m.pay_period_end)                                               AS latest_period_end
  FROM public.clinician_visit_period_metrics m
  WHERE m.visit_count > 0
  GROUP BY m.clinician_id, m.clinician_name;
$$;

REVOKE ALL ON FUNCTION public.upsert_clinician_visit_periods(JSONB) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.list_clinician_visit_summary()        FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.upsert_clinician_visit_periods(JSONB) TO authenticated;
GRANT EXECUTE ON FUNCTION public.list_clinician_visit_summary()        TO authenticated;

COMMIT;

NOTIFY pgrst, 'reload schema';
