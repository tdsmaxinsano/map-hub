-- Patient Check Deposit History
-- =====================================================================
-- Backs the new "③ Patient Deposit History" card in the Finance →
-- QB Tools sub-view. Every patient check scanned via 📷 Scan a
-- patient check (Bank Match modal) AND routed to Accounts Receivable
-- is logged here automatically when the user clicks "Add to batch".
--
-- The history lets the user track which scanned checks still need to
-- be CLEARED in Strata EMR — Strata is a separate system that also
-- tracks patient balances, and the QB-side Bank Deposit doesn't
-- automatically tell Strata the balance was paid. Without this
-- history, scanned checks pile up in Strata as "still owed" forever.
--
-- Schema decisions:
-- - Single boolean flag `strata_cleared` + audit timestamps. No
--   QB-applied tracking (accountant handles that separately).
-- - `category` column reserved for future expansion (e.g., adding
--   carrier-check tracking) so we don't need a new migration for
--   that schema change.
-- - Admin-only RLS matching the Finance posture.
--
-- Idempotent — safe to re-run.
-- Run after: 01_phase1_enable_rls.sql (depends on user_roles).

BEGIN;

-- ── 1. Table ──────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.patient_check_deposits (
  id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),

  -- Check identification (OCR-extracted, user-confirmed)
  payer_name          TEXT NOT NULL,
  amount              NUMERIC(10,2) NOT NULL,
  check_date          DATE,
  check_number        TEXT,
  memo                TEXT,

  -- Routing context (gl_account is informational; pattern future-proofs)
  gl_account          TEXT,         -- e.g., "Accounts Receivable"
  category            TEXT NOT NULL DEFAULT 'patient',   -- 'patient' v1; future: 'carrier'

  -- Audit: scan
  scanned_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  scanned_by          UUID REFERENCES auth.users(id),

  -- Strata-cleared tracking (the reason this table exists)
  strata_cleared      BOOLEAN NOT NULL DEFAULT FALSE,
  strata_cleared_at   TIMESTAMPTZ,
  strata_cleared_by   UUID REFERENCES auth.users(id),

  -- Misc / future
  notes               TEXT,
  updated_at          TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS pcd_scanned_at_idx
  ON public.patient_check_deposits (scanned_at DESC);
CREATE INDEX IF NOT EXISTS pcd_payer_idx
  ON public.patient_check_deposits (payer_name);
CREATE INDEX IF NOT EXISTS pcd_cleared_idx
  ON public.patient_check_deposits (strata_cleared, scanned_at DESC);
CREATE INDEX IF NOT EXISTS pcd_category_idx
  ON public.patient_check_deposits (category);

-- updated_at touch trigger
CREATE OR REPLACE FUNCTION public.pcd_touch_updated_at()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  NEW.updated_at := NOW();
  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS pcd_touch_updated_at_trg ON public.patient_check_deposits;
CREATE TRIGGER pcd_touch_updated_at_trg
  BEFORE UPDATE ON public.patient_check_deposits
  FOR EACH ROW EXECUTE FUNCTION public.pcd_touch_updated_at();

-- ── 2. RLS ────────────────────────────────────────────────────────
ALTER TABLE public.patient_check_deposits ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "pcd_admin_read"  ON public.patient_check_deposits;
DROP POLICY IF EXISTS "pcd_admin_write" ON public.patient_check_deposits;

CREATE POLICY "pcd_admin_read" ON public.patient_check_deposits
  FOR SELECT TO authenticated
  USING (EXISTS (SELECT 1 FROM public.user_roles ur
                 WHERE ur.user_id = auth.uid() AND ur.role = 'admin'));

CREATE POLICY "pcd_admin_write" ON public.patient_check_deposits
  FOR ALL TO authenticated
  USING      (EXISTS (SELECT 1 FROM public.user_roles ur
                      WHERE ur.user_id = auth.uid() AND ur.role = 'admin'))
  WITH CHECK (EXISTS (SELECT 1 FROM public.user_roles ur
                      WHERE ur.user_id = auth.uid() AND ur.role = 'admin'));

-- ── 3. RPC: insert_patient_check_deposit ──────────────────────────
-- Returns the inserted row's id. Called from the BANK module's
-- addScannedRow() when a scan is AR-routed (Path-1 patient co-pay).
CREATE OR REPLACE FUNCTION public.insert_patient_check_deposit(
  p_payer_name   TEXT,
  p_amount       NUMERIC,
  p_check_date   DATE,
  p_check_number TEXT,
  p_memo         TEXT,
  p_gl_account   TEXT,
  p_category     TEXT DEFAULT 'patient'
)
RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  new_id UUID;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM user_roles ur
                 WHERE ur.user_id = auth.uid() AND ur.role = 'admin') THEN
    RAISE EXCEPTION 'Only admin may log patient check deposits';
  END IF;
  IF p_payer_name IS NULL OR TRIM(p_payer_name) = '' THEN
    RAISE EXCEPTION 'payer_name required';
  END IF;
  IF p_amount IS NULL OR p_amount <= 0 THEN
    RAISE EXCEPTION 'amount must be positive';
  END IF;

  INSERT INTO patient_check_deposits (
    payer_name, amount, check_date, check_number, memo,
    gl_account, category,
    scanned_by
  ) VALUES (
    TRIM(p_payer_name), p_amount, p_check_date, p_check_number, p_memo,
    p_gl_account, COALESCE(p_category, 'patient'),
    auth.uid()
  )
  RETURNING id INTO new_id;

  RETURN new_id;
END $$;

REVOKE ALL ON FUNCTION public.insert_patient_check_deposit(
  TEXT, NUMERIC, DATE, TEXT, TEXT, TEXT, TEXT
) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.insert_patient_check_deposit(
  TEXT, NUMERIC, DATE, TEXT, TEXT, TEXT, TEXT
) TO authenticated;

-- ── 4. RPC: list_patient_check_deposits ───────────────────────────
-- Filter knobs:
--   * p_only_pending: true → only rows where strata_cleared = false
--   * p_search: case-insensitive substring on payer_name
--   * p_limit: cap (default 200)
--
-- NOTE: every returned column needs an explicit ::TYPE cast that
-- matches the RETURNS TABLE declaration exactly. Postgres is strict —
-- amount is NUMERIC(10,2) in the table but RETURNS NUMERIC; subquery
-- columns like auth.users.email are VARCHAR not TEXT. Both mismatches
-- trigger "structure of query does not match function result type"
-- at runtime.
DROP FUNCTION IF EXISTS public.list_patient_check_deposits(BOOLEAN, TEXT, INTEGER);
CREATE OR REPLACE FUNCTION public.list_patient_check_deposits(
  p_only_pending BOOLEAN DEFAULT FALSE,
  p_search       TEXT    DEFAULT NULL,
  p_limit        INTEGER DEFAULT 200
)
RETURNS TABLE (
  id                UUID,
  payer_name        TEXT,
  amount            NUMERIC,
  check_date        DATE,
  check_number      TEXT,
  memo              TEXT,
  gl_account        TEXT,
  category          TEXT,
  scanned_at        TIMESTAMPTZ,
  scanned_by        UUID,
  scanned_by_email  TEXT,
  strata_cleared    BOOLEAN,
  strata_cleared_at TIMESTAMPTZ,
  strata_cleared_by UUID,
  strata_cleared_by_email TEXT,
  notes             TEXT
)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM user_roles ur
                 WHERE ur.user_id = auth.uid() AND ur.role = 'admin') THEN
    RAISE EXCEPTION 'Only admin may list patient check deposits';
  END IF;

  RETURN QUERY
    SELECT
      d.id,
      d.payer_name::TEXT,
      d.amount::NUMERIC,
      d.check_date,
      d.check_number::TEXT,
      d.memo::TEXT,
      d.gl_account::TEXT,
      d.category::TEXT,
      d.scanned_at,
      d.scanned_by,
      (SELECT u.email::TEXT FROM auth.users u WHERE u.id = d.scanned_by) AS scanned_by_email,
      d.strata_cleared,
      d.strata_cleared_at,
      d.strata_cleared_by,
      (SELECT u.email::TEXT FROM auth.users u WHERE u.id = d.strata_cleared_by) AS strata_cleared_by_email,
      d.notes::TEXT
    FROM patient_check_deposits d
    WHERE d.category = 'patient'
      AND (NOT COALESCE(p_only_pending, FALSE) OR NOT d.strata_cleared)
      AND (p_search IS NULL OR TRIM(p_search) = ''
           OR d.payer_name ILIKE '%' || TRIM(p_search) || '%'
           OR d.memo       ILIKE '%' || TRIM(p_search) || '%'
           OR d.check_number ILIKE '%' || TRIM(p_search) || '%')
    ORDER BY d.scanned_at DESC
    LIMIT COALESCE(p_limit, 200);
END $$;

REVOKE ALL ON FUNCTION public.list_patient_check_deposits(BOOLEAN, TEXT, INTEGER) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.list_patient_check_deposits(BOOLEAN, TEXT, INTEGER) TO authenticated;

-- ── 5. RPC: mark_patient_check_cleared ────────────────────────────
-- Toggle the Strata-cleared flag with audit. p_cleared=true stamps
-- the timestamp + actor; p_cleared=false clears them.
CREATE OR REPLACE FUNCTION public.mark_patient_check_cleared(
  p_id      UUID,
  p_cleared BOOLEAN DEFAULT TRUE
)
RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM user_roles ur
                 WHERE ur.user_id = auth.uid() AND ur.role = 'admin') THEN
    RAISE EXCEPTION 'Only admin may mark Strata-cleared';
  END IF;

  UPDATE patient_check_deposits
  SET strata_cleared    = COALESCE(p_cleared, TRUE),
      strata_cleared_at = CASE WHEN COALESCE(p_cleared, TRUE) THEN NOW() ELSE NULL END,
      strata_cleared_by = CASE WHEN COALESCE(p_cleared, TRUE) THEN auth.uid() ELSE NULL END
  WHERE id = p_id;
END $$;

REVOKE ALL ON FUNCTION public.mark_patient_check_cleared(UUID, BOOLEAN) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.mark_patient_check_cleared(UUID, BOOLEAN) TO authenticated;

-- ── 6. RPC: update_patient_check_notes ────────────────────────────
-- Free-form notes editor for a row.
CREATE OR REPLACE FUNCTION public.update_patient_check_notes(
  p_id    UUID,
  p_notes TEXT
)
RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM user_roles ur
                 WHERE ur.user_id = auth.uid() AND ur.role = 'admin') THEN
    RAISE EXCEPTION 'Only admin may edit deposit notes';
  END IF;

  UPDATE patient_check_deposits
  SET notes = p_notes
  WHERE id = p_id;
END $$;

REVOKE ALL ON FUNCTION public.update_patient_check_notes(UUID, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.update_patient_check_notes(UUID, TEXT) TO authenticated;

-- ── 7. RPC: delete_patient_check_deposit ──────────────────────────
-- Hard delete — used when the user added a check by mistake.
-- Two-click confirm lives on the client side.
CREATE OR REPLACE FUNCTION public.delete_patient_check_deposit(p_id UUID)
RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM user_roles ur
                 WHERE ur.user_id = auth.uid() AND ur.role = 'admin') THEN
    RAISE EXCEPTION 'Only admin may delete deposit history';
  END IF;

  DELETE FROM patient_check_deposits WHERE id = p_id;
END $$;

REVOKE ALL ON FUNCTION public.delete_patient_check_deposit(UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.delete_patient_check_deposit(UUID) TO authenticated;

COMMIT;

NOTIFY pgrst, 'reload schema';
