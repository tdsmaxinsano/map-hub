-- Clinician Payroll — store the source Strata Med B PDF (reference / audit)
-- =====================================================================
-- Background: the Med B import parses a Strata "Staff Productivity Report"
-- PDF in the browser and keeps only the derived per-clinician numbers — the
-- original PDF bytes are discarded after parsing. After repeated parser-
-- accuracy pain, we now retain the source PDF so admins can reopen the
-- ground-truth document to verify a number or settle a dispute.
--
-- Scope is reference/audit-trail only: store the PDF + surface a "View source
-- PDF" link on the audit detail and history row. Re-importing for a period
-- replaces the stored PDF (deterministic per-period path + upsert).
--
-- Mirrors the existing `vdr-reports` storage posture exactly (migration 08):
-- a PRIVATE, admin-only bucket. The Strata report carries clinician names +
-- visit + billing data (business-sensitive; not patient PHI), so admin-only
-- read is the right RLS.
--
-- Additive + idempotent. Existing runs load cleanly with medb_pdf_path NULL.

BEGIN;

-- ── 1. Storage bucket: strata-medb-pdfs (private, admin-only) ───────
INSERT INTO storage.buckets (id, name, public)
VALUES ('strata-medb-pdfs', 'strata-medb-pdfs', false)
ON CONFLICT (id) DO NOTHING;

DROP POLICY IF EXISTS "strata_medb_pdfs_admin_read"  ON storage.objects;
DROP POLICY IF EXISTS "strata_medb_pdfs_admin_write" ON storage.objects;

CREATE POLICY "strata_medb_pdfs_admin_read" ON storage.objects
  FOR SELECT TO authenticated
  USING (bucket_id = 'strata-medb-pdfs'
         AND EXISTS (SELECT 1 FROM public.user_roles WHERE user_id = auth.uid() AND role = 'admin'));

CREATE POLICY "strata_medb_pdfs_admin_write" ON storage.objects
  FOR ALL TO authenticated
  USING (bucket_id = 'strata-medb-pdfs'
         AND EXISTS (SELECT 1 FROM public.user_roles WHERE user_id = auth.uid() AND role = 'admin'))
  WITH CHECK (bucket_id = 'strata-medb-pdfs'
              AND EXISTS (SELECT 1 FROM public.user_roles WHERE user_id = auth.uid() AND role = 'admin'));

-- ── 2. Path column on the payroll run ──────────────────────────────
-- Holds the storage object path (e.g. 'medb-2026-05-17.pdf'). NULL for
-- runs saved without a Strata PDF. Reference-only — never parsed.
ALTER TABLE public.clinician_payroll_runs
  ADD COLUMN IF NOT EXISTS medb_pdf_path TEXT;

-- ── 3. Extended upsert RPC — adds p_medb_pdf_path (last param) ──────
-- DROP the migration-34 13-arg signature first; adding a param is a
-- signature change. On conflict, COALESCE so a save that doesn't re-upload
-- a PDF (p_medb_pdf_path NULL) preserves the previously stored path.
DROP FUNCTION IF EXISTS public.upsert_clinician_payroll_run(
  DATE, DATE, DATE, NUMERIC, NUMERIC, NUMERIC, INTEGER, INTEGER, INTEGER, INTEGER, JSONB, JSONB, TEXT
);

CREATE OR REPLACE FUNCTION public.upsert_clinician_payroll_run(
  p_period_start          DATE,
  p_period_end            DATE,
  p_pay_date              DATE,
  p_total_pay             NUMERIC,
  p_total_expenses        NUMERIC,
  p_total_medb            NUMERIC,
  p_total_visits          INTEGER,
  p_payable_visits        INTEGER,
  p_nonpayable_visits     INTEGER,
  p_distinct_clinicians   INTEGER,
  p_per_clinician_payload JSONB,
  p_all_visits_payload    JSONB,
  p_source_filename       TEXT,
  p_medb_pdf_path         TEXT DEFAULT NULL   -- NEW (source-PDF reference)
)
RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE run_id UUID;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM user_roles ur
                 WHERE ur.user_id = auth.uid() AND ur.role = 'admin') THEN
    RAISE EXCEPTION 'Only admin may import clinician payroll runs';
  END IF;

  INSERT INTO clinician_payroll_runs
    (period_start, period_end, pay_date,
     total_pay, total_expenses, total_medb, total_visits,
     payable_visits, nonpayable_visits, distinct_clinicians,
     per_clinician_payload, all_visits_payload,
     source_filename, medb_pdf_path, imported_at, imported_by)
  VALUES
    (p_period_start, p_period_end, p_pay_date,
     p_total_pay, p_total_expenses, COALESCE(p_total_medb, 0), p_total_visits,
     p_payable_visits, p_nonpayable_visits, p_distinct_clinicians,
     COALESCE(p_per_clinician_payload, '[]'::jsonb),
     COALESCE(p_all_visits_payload, '[]'::jsonb),
     p_source_filename, p_medb_pdf_path, now(), auth.uid())
  ON CONFLICT (period_start, period_end) DO UPDATE
    SET pay_date              = EXCLUDED.pay_date,
        total_pay             = EXCLUDED.total_pay,
        total_expenses        = EXCLUDED.total_expenses,
        total_medb            = EXCLUDED.total_medb,
        total_visits          = EXCLUDED.total_visits,
        payable_visits        = EXCLUDED.payable_visits,
        nonpayable_visits     = EXCLUDED.nonpayable_visits,
        distinct_clinicians   = EXCLUDED.distinct_clinicians,
        per_clinician_payload = EXCLUDED.per_clinician_payload,
        all_visits_payload    = EXCLUDED.all_visits_payload,
        source_filename       = EXCLUDED.source_filename,
        -- Preserve an existing PDF when this save didn't upload a new one.
        medb_pdf_path         = COALESCE(EXCLUDED.medb_pdf_path, clinician_payroll_runs.medb_pdf_path),
        imported_at           = now(),
        imported_by           = auth.uid()
    -- NOTE: audit state (status, audited_*, exported_*) is preserved
    -- on re-import (same rule as migration 19).
  RETURNING id INTO run_id;

  RETURN run_id;
END $$;

REVOKE ALL ON FUNCTION public.upsert_clinician_payroll_run(
  DATE, DATE, DATE, NUMERIC, NUMERIC, NUMERIC, INTEGER, INTEGER, INTEGER, INTEGER, JSONB, JSONB, TEXT, TEXT
) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.upsert_clinician_payroll_run(
  DATE, DATE, DATE, NUMERIC, NUMERIC, NUMERIC, INTEGER, INTEGER, INTEGER, INTEGER, JSONB, JSONB, TEXT, TEXT
) TO authenticated;

-- ── 4. Extended list RPC — adds medb_pdf_path to summary row ────────
-- Same DROP-then-CREATE pattern (return-table shape changes).
DROP FUNCTION IF EXISTS public.list_clinician_payroll_runs();

CREATE OR REPLACE FUNCTION public.list_clinician_payroll_runs()
RETURNS TABLE(
  id                  UUID,
  period_start        DATE,
  period_end          DATE,
  pay_date            DATE,
  total_pay           NUMERIC,
  total_medb          NUMERIC,
  total_visits        INTEGER,
  payable_visits      INTEGER,
  nonpayable_visits   INTEGER,
  distinct_clinicians INTEGER,
  status              TEXT,
  audited_at          TIMESTAMPTZ,
  exported_at         TIMESTAMPTZ,
  paid_at             TIMESTAMPTZ,
  imported_at         TIMESTAMPTZ,
  source_filename     TEXT,
  medb_pdf_path       TEXT   -- NEW
)
LANGUAGE sql SECURITY DEFINER SET search_path = public AS $$
  SELECT
    id, period_start, period_end, pay_date,
    total_pay, total_medb,
    total_visits, payable_visits, nonpayable_visits,
    distinct_clinicians, status,
    audited_at, exported_at, paid_at, imported_at, source_filename,
    medb_pdf_path
  FROM public.clinician_payroll_runs
  ORDER BY period_end DESC;
$$;

REVOKE ALL ON FUNCTION public.list_clinician_payroll_runs() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.list_clinician_payroll_runs() TO authenticated;

-- ── 5. get_clinician_payroll_run unchanged ─────────────────────────
-- Returns SETOF clinician_payroll_runs so the new `medb_pdf_path`
-- column is automatically included. No DROP / CREATE needed.

COMMIT;

NOTIFY pgrst, 'reload schema';
