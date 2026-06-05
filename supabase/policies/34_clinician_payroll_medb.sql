-- Clinician Payroll — Strata Med B parallel pay stream
-- =====================================================================
-- Background: each pay period, every clinician's QB payable is split
-- across TWO Bills sharing the same pay-period Bill # (e.g.,
-- 05032026-05162026):
--   • Regular Pay  — from TB "Prepare payroll" export (existing flow,
--                    migration 19). Stored in `total_pay` + each
--                    per-clinician row's `pay_total`.
--   • Strata Med B — from a Strata EMR export (this migration). Stored
--                    in the new `total_medb` top-line column + each
--                    per-clinician row's NEW `medb_total` JSONB field
--                    inside `per_clinician_payload`.
--
-- Both Bills are normally routed to the same per-discipline GL
-- (`Subcontractor:PT` / `Subcontractor:OT` / etc.) in QB; the split is
-- bookkeeping so accounting can see the two revenue sources separately.
--
-- This migration is additive + idempotent. The Strata file is OPTIONAL —
-- existing payroll runs (pre-migration) load cleanly with Med B = 0
-- across the board. UI defaults to 0 when no Strata file is dropped.
--
-- Why a JSONB extension instead of a relational table for per-clinician
-- Med B? The existing `per_clinician_payload JSONB` already carries the
-- per-clinician aggregates (pay_total / expenses_total / visit counts /
-- discipline). Adding `medb_total` + `medb_source` inside that JSONB is
-- forward-compatible with the current code path (reads default missing
-- fields to 0) and doesn't fragment the aggregate snapshot.
--
-- Future Phase 3 (QB Bill export) will read `discipline` + `pay_total`
-- + `medb_total` per clinician and emit TWO Bill lines per clinician
-- per period — both routed to `Subcontractor:<discipline>`, sharing
-- the same Bill # (the pay-period date pair).
--
-- Admin-only RLS across the board (matches migration 19's posture).
-- Idempotent — safe to re-run.

BEGIN;

-- ── 1. Top-line column ─────────────────────────────────────────────
-- Adds `total_medb` — the period-wide sum of all clinicians' Med B
-- pay. Defaults to 0 so existing rows are valid without backfill.
-- History/trend views can plot this alongside `total_pay` without
-- re-parsing `per_clinician_payload` JSONB.
ALTER TABLE public.clinician_payroll_runs
  ADD COLUMN IF NOT EXISTS total_medb NUMERIC(12,2) NOT NULL DEFAULT 0;

-- ── 2. Extended upsert RPC ─────────────────────────────────────────
-- New signature adds `p_total_medb` after `p_total_expenses`. Drop
-- the old signature first because adding a param mid-signature is a
-- signature change that ON CONFLICT REPLACE alone can't handle.
DROP FUNCTION IF EXISTS public.upsert_clinician_payroll_run(
  DATE, DATE, DATE, NUMERIC, NUMERIC, INTEGER, INTEGER, INTEGER, INTEGER, JSONB, JSONB, TEXT
);

CREATE OR REPLACE FUNCTION public.upsert_clinician_payroll_run(
  p_period_start          DATE,
  p_period_end            DATE,
  p_pay_date              DATE,
  p_total_pay             NUMERIC,
  p_total_expenses        NUMERIC,
  p_total_medb            NUMERIC,   -- NEW (Phase 1 Strata Med B)
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
     total_pay, total_expenses, total_medb, total_visits,
     payable_visits, nonpayable_visits, distinct_clinicians,
     per_clinician_payload, all_visits_payload,
     source_filename, imported_at, imported_by)
  VALUES
    (p_period_start, p_period_end, p_pay_date,
     p_total_pay, p_total_expenses, COALESCE(p_total_medb, 0), p_total_visits,
     p_payable_visits, p_nonpayable_visits, p_distinct_clinicians,
     COALESCE(p_per_clinician_payload, '[]'::jsonb),
     COALESCE(p_all_visits_payload, '[]'::jsonb),
     p_source_filename, now(), auth.uid())
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
        imported_at           = now(),
        imported_by           = auth.uid()
    -- NOTE: audit state (status, audited_*, exported_*) is preserved
    -- on re-import (same rule as migration 19).
  RETURNING id INTO run_id;

  RETURN run_id;
END $$;

REVOKE ALL ON FUNCTION public.upsert_clinician_payroll_run(
  DATE, DATE, DATE, NUMERIC, NUMERIC, NUMERIC, INTEGER, INTEGER, INTEGER, INTEGER, JSONB, JSONB, TEXT
) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.upsert_clinician_payroll_run(
  DATE, DATE, DATE, NUMERIC, NUMERIC, NUMERIC, INTEGER, INTEGER, INTEGER, INTEGER, JSONB, JSONB, TEXT
) TO authenticated;

-- ── 3. Extended list RPC (adds total_medb to summary row) ──────────
-- Same DROP-then-CREATE pattern because the return-table shape
-- changes (new column at the end).
DROP FUNCTION IF EXISTS public.list_clinician_payroll_runs();

CREATE OR REPLACE FUNCTION public.list_clinician_payroll_runs()
RETURNS TABLE(
  id                  UUID,
  period_start        DATE,
  period_end          DATE,
  pay_date            DATE,
  total_pay           NUMERIC,
  total_medb          NUMERIC,   -- NEW
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
    total_pay, total_medb,
    total_visits, payable_visits, nonpayable_visits,
    distinct_clinicians, status,
    audited_at, exported_at, paid_at, imported_at, source_filename
  FROM public.clinician_payroll_runs
  ORDER BY period_end DESC;
$$;

REVOKE ALL ON FUNCTION public.list_clinician_payroll_runs() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.list_clinician_payroll_runs() TO authenticated;

-- ── 4. get_clinician_payroll_run unchanged ─────────────────────────
-- Returns SETOF clinician_payroll_runs so the new `total_medb`
-- column is automatically included. No DROP / CREATE needed.

COMMIT;

NOTIFY pgrst, 'reload schema';
