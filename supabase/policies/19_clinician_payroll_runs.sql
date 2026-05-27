-- Clinician Payroll — TB Prepare-payroll audit + history
-- =====================================================================
-- Stores one row per pay-period audit of the TB "Prepare payroll" Excel
-- export. The user's audit workflow:
--   1. TB → Prepare payroll → download .xlsx
--   2. Drop into Finance → Payroll → Clinician Payroll Audit
--   3. Tool parses + aggregates + flags anomalies
--   4. If discrepancies → fix in TB, re-export, re-import
--   5. Once clean → mark "audited", lock the run
--   6. Phase 3 — Export to QuickBooks (separate flow)
--
-- Schema captures:
--   * Period bounds + pay date (matches the Sun-Sat / Mon-pay calendar)
--   * Top-line totals (pay, visit count, payable / non-payable breakdown)
--   * Status state machine (open → audited → exported → paid)
--   * Per-clinician aggregate JSONB (drives the inline audit table)
--   * Per-visit raw payload JSONB (lets us re-render the drill-down
--     without re-uploading the file)
--
-- Admin-only across the board (Finance area is already admin-gated).
-- Idempotent — safe to re-run.

BEGIN;

CREATE TABLE IF NOT EXISTS public.clinician_payroll_runs (
  id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),

  -- Period anchors (Sun-Sat bi-weekly, pay date = period_end + 16 days = Mon)
  period_start        DATE NOT NULL,
  period_end          DATE NOT NULL,
  pay_date            DATE NOT NULL,

  -- Top-line totals
  total_pay           NUMERIC(12,2) NOT NULL DEFAULT 0,
  total_expenses      NUMERIC(12,2) NOT NULL DEFAULT 0,
  total_visits        INTEGER       NOT NULL DEFAULT 0,
  payable_visits      INTEGER       NOT NULL DEFAULT 0,
  nonpayable_visits   INTEGER       NOT NULL DEFAULT 0,
  distinct_clinicians INTEGER       NOT NULL DEFAULT 0,

  -- Audit state machine
  status              TEXT NOT NULL DEFAULT 'open',
                      -- 'open' | 'audited' | 'exported' | 'paid'
  audited_at          TIMESTAMPTZ,
  audited_by          UUID,
  audit_notes         TEXT,
  exported_at         TIMESTAMPTZ,
  exported_by         UUID,
  paid_at             TIMESTAMPTZ,
  paid_by             UUID,

  -- Snapshots (drive inline re-display + QB export without re-upload)
  per_clinician_payload JSONB NOT NULL DEFAULT '[]'::jsonb,
  all_visits_payload    JSONB NOT NULL DEFAULT '[]'::jsonb,

  source_filename     TEXT,
  imported_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
  imported_by         UUID NOT NULL DEFAULT auth.uid(),

  UNIQUE (period_start, period_end)
);

CREATE INDEX IF NOT EXISTS idx_cpr_period_end ON public.clinician_payroll_runs (period_end DESC);
CREATE INDEX IF NOT EXISTS idx_cpr_status     ON public.clinician_payroll_runs (status);

-- ── RLS — admin only ───────────────────────────────────────────────
ALTER TABLE public.clinician_payroll_runs ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "cpr_admin_all" ON public.clinician_payroll_runs;
CREATE POLICY "cpr_admin_all" ON public.clinician_payroll_runs
  FOR ALL TO authenticated
  USING      (EXISTS (SELECT 1 FROM public.user_roles ur
                      WHERE ur.user_id = auth.uid() AND ur.role = 'admin'))
  WITH CHECK (EXISTS (SELECT 1 FROM public.user_roles ur
                      WHERE ur.user_id = auth.uid() AND ur.role = 'admin'));

-- ── RPC: upsert a run (admin only) ─────────────────────────────────
-- Re-import for the same period replaces the data (user may upload an
-- updated TB file after making corrections). Audit state is preserved
-- across re-imports unless the user explicitly resets it.
CREATE OR REPLACE FUNCTION public.upsert_clinician_payroll_run(
  p_period_start          DATE,
  p_period_end            DATE,
  p_pay_date              DATE,
  p_total_pay             NUMERIC,
  p_total_expenses        NUMERIC,
  p_total_visits          INTEGER,
  p_payable_visits        INTEGER,
  p_nonpayable_visits     INTEGER,
  p_distinct_clinicians   INTEGER,
  p_per_clinician_payload JSONB,
  p_all_visits_payload    JSONB,
  p_source_filename       TEXT
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
     total_pay, total_expenses, total_visits,
     payable_visits, nonpayable_visits, distinct_clinicians,
     per_clinician_payload, all_visits_payload,
     source_filename, imported_at, imported_by)
  VALUES
    (p_period_start, p_period_end, p_pay_date,
     p_total_pay, p_total_expenses, p_total_visits,
     p_payable_visits, p_nonpayable_visits, p_distinct_clinicians,
     COALESCE(p_per_clinician_payload, '[]'::jsonb),
     COALESCE(p_all_visits_payload, '[]'::jsonb),
     p_source_filename, now(), auth.uid())
  ON CONFLICT (period_start, period_end) DO UPDATE
    SET pay_date              = EXCLUDED.pay_date,
        total_pay             = EXCLUDED.total_pay,
        total_expenses        = EXCLUDED.total_expenses,
        total_visits          = EXCLUDED.total_visits,
        payable_visits        = EXCLUDED.payable_visits,
        nonpayable_visits     = EXCLUDED.nonpayable_visits,
        distinct_clinicians   = EXCLUDED.distinct_clinicians,
        per_clinician_payload = EXCLUDED.per_clinician_payload,
        all_visits_payload    = EXCLUDED.all_visits_payload,
        source_filename       = EXCLUDED.source_filename,
        imported_at           = now(),
        imported_by           = auth.uid()
    -- NOTE: audit state (status, audited_*, exported_*) is preserved
    -- on re-import. To reset, the user uses a separate "reset audit"
    -- action (not yet built — Phase 2b).
  RETURNING id INTO run_id;

  RETURN run_id;
END $$;

-- ── RPC: list runs (admin only) — returns top-line summary ─────────
CREATE OR REPLACE FUNCTION public.list_clinician_payroll_runs()
RETURNS TABLE(
  id                  UUID,
  period_start        DATE,
  period_end          DATE,
  pay_date            DATE,
  total_pay           NUMERIC,
  total_visits        INTEGER,
  payable_visits      INTEGER,
  nonpayable_visits   INTEGER,
  distinct_clinicians INTEGER,
  status              TEXT,
  audited_at          TIMESTAMPTZ,
  exported_at         TIMESTAMPTZ,
  paid_at             TIMESTAMPTZ,
  imported_at         TIMESTAMPTZ,
  source_filename     TEXT
)
LANGUAGE sql SECURITY DEFINER SET search_path = public AS $$
  SELECT
    id, period_start, period_end, pay_date,
    total_pay, total_visits, payable_visits, nonpayable_visits,
    distinct_clinicians, status,
    audited_at, exported_at, paid_at, imported_at, source_filename
  FROM public.clinician_payroll_runs
  ORDER BY period_end DESC;
$$;

-- ── RPC: load full run detail (admin only) — drives the audit view ─
CREATE OR REPLACE FUNCTION public.get_clinician_payroll_run(run_id UUID)
RETURNS SETOF public.clinician_payroll_runs
LANGUAGE sql SECURITY DEFINER SET search_path = public AS $$
  SELECT * FROM public.clinician_payroll_runs WHERE id = run_id LIMIT 1;
$$;

-- ── RPC: state transitions (admin only) ────────────────────────────
CREATE OR REPLACE FUNCTION public.mark_clinician_payroll_audited(
  run_id UUID,
  notes  TEXT DEFAULT NULL
)
RETURNS public.clinician_payroll_runs
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE r public.clinician_payroll_runs;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM user_roles ur
                 WHERE ur.user_id = auth.uid() AND ur.role = 'admin') THEN
    RAISE EXCEPTION 'Only admin may audit payroll runs';
  END IF;
  UPDATE clinician_payroll_runs SET
    status      = 'audited',
    audited_at  = now(),
    audited_by  = auth.uid(),
    audit_notes = COALESCE(notes, audit_notes)
  WHERE id = run_id
  RETURNING * INTO r;
  RETURN r;
END $$;

CREATE OR REPLACE FUNCTION public.mark_clinician_payroll_exported(run_id UUID)
RETURNS public.clinician_payroll_runs
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE r public.clinician_payroll_runs;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM user_roles ur
                 WHERE ur.user_id = auth.uid() AND ur.role = 'admin') THEN
    RAISE EXCEPTION 'Only admin may export payroll runs';
  END IF;
  UPDATE clinician_payroll_runs SET
    status      = 'exported',
    exported_at = now(),
    exported_by = auth.uid()
  WHERE id = run_id
  RETURNING * INTO r;
  RETURN r;
END $$;

CREATE OR REPLACE FUNCTION public.mark_clinician_payroll_paid(run_id UUID)
RETURNS public.clinician_payroll_runs
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE r public.clinician_payroll_runs;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM user_roles ur
                 WHERE ur.user_id = auth.uid() AND ur.role = 'admin') THEN
    RAISE EXCEPTION 'Only admin may mark payroll paid';
  END IF;
  UPDATE clinician_payroll_runs SET
    status  = 'paid',
    paid_at = now(),
    paid_by = auth.uid()
  WHERE id = run_id
  RETURNING * INTO r;
  RETURN r;
END $$;

-- ── RPC: delete a run (admin only) ─────────────────────────────────
-- For when a file is uploaded against the wrong period or the period
-- is otherwise junk. Hard delete — the period can be re-imported fresh.
CREATE OR REPLACE FUNCTION public.delete_clinician_payroll_run(run_id UUID)
RETURNS INTEGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE n INT;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM user_roles ur
                 WHERE ur.user_id = auth.uid() AND ur.role = 'admin') THEN
    RAISE EXCEPTION 'Only admin may delete payroll runs';
  END IF;
  -- Supabase requires DELETE to have a WHERE clause; this satisfies that.
  DELETE FROM clinician_payroll_runs WHERE id = run_id;
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END $$;

REVOKE ALL ON FUNCTION public.upsert_clinician_payroll_run(DATE, DATE, DATE, NUMERIC, NUMERIC, INTEGER, INTEGER, INTEGER, INTEGER, JSONB, JSONB, TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.list_clinician_payroll_runs()                  FROM PUBLIC;
REVOKE ALL ON FUNCTION public.get_clinician_payroll_run(UUID)                FROM PUBLIC;
REVOKE ALL ON FUNCTION public.mark_clinician_payroll_audited(UUID, TEXT)     FROM PUBLIC;
REVOKE ALL ON FUNCTION public.mark_clinician_payroll_exported(UUID)          FROM PUBLIC;
REVOKE ALL ON FUNCTION public.mark_clinician_payroll_paid(UUID)              FROM PUBLIC;
REVOKE ALL ON FUNCTION public.delete_clinician_payroll_run(UUID)             FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.upsert_clinician_payroll_run(DATE, DATE, DATE, NUMERIC, NUMERIC, INTEGER, INTEGER, INTEGER, INTEGER, JSONB, JSONB, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.list_clinician_payroll_runs()                TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_clinician_payroll_run(UUID)              TO authenticated;
GRANT EXECUTE ON FUNCTION public.mark_clinician_payroll_audited(UUID, TEXT)   TO authenticated;
GRANT EXECUTE ON FUNCTION public.mark_clinician_payroll_exported(UUID)        TO authenticated;
GRANT EXECUTE ON FUNCTION public.mark_clinician_payroll_paid(UUID)            TO authenticated;
GRANT EXECUTE ON FUNCTION public.delete_clinician_payroll_run(UUID)           TO authenticated;

COMMIT;

NOTIFY pgrst, 'reload schema';
