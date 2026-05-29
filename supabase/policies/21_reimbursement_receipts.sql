-- Reimbursements + receipt attachments on pay-period adjustments
-- =====================================================================
-- PH staff frequently buy something locally (in pesos) and get reimbursed.
-- The Pay Period adjustment flow now supports a "reimbursement" kind with:
--   * a PHP→USD conversion at entry time (the table stores USD in `amount`,
--     so all existing payroll / Send-via-Wise math is unchanged), and
--   * an attached receipt image/PDF stored in a public-read bucket.
--
-- `pay_period_adjustments` is an ad-hoc table (no prior migration), so this
-- just adds nullable columns + a storage bucket. The original peso amount,
-- currency, and FX rate are preserved for the audit trail.
--
-- Mirrors the bucket/policy pattern from 03_staff_directory.sql.
-- Idempotent — safe to re-run.

BEGIN;

-- ─── Adjustment columns ──────────────────────────────────────────────
ALTER TABLE public.pay_period_adjustments
  ADD COLUMN IF NOT EXISTS kind              TEXT DEFAULT 'bonus',  -- bonus | deduction | reimbursement
  ADD COLUMN IF NOT EXISTS receipt_url       TEXT,
  ADD COLUMN IF NOT EXISTS original_amount   NUMERIC,               -- amount as entered (in original_currency)
  ADD COLUMN IF NOT EXISTS original_currency TEXT,                  -- 'PHP' | 'USD'
  ADD COLUMN IF NOT EXISTS fx_rate           NUMERIC;               -- PHP-per-USD rate used at entry

-- ─── Storage: reimbursement-receipts bucket (public-read, admin-write) ─
INSERT INTO storage.buckets (id, name, public)
VALUES ('reimbursement-receipts', 'reimbursement-receipts', true)
ON CONFLICT (id) DO UPDATE SET public = true;

-- Read access for any authenticated user
DROP POLICY IF EXISTS "reimbursement_receipts_read_authenticated" ON storage.objects;
CREATE POLICY "reimbursement_receipts_read_authenticated" ON storage.objects
  FOR SELECT TO authenticated
  USING (bucket_id = 'reimbursement-receipts');

-- Write access (insert/update/delete) only for admins
DROP POLICY IF EXISTS "reimbursement_receipts_admin_write" ON storage.objects;
CREATE POLICY "reimbursement_receipts_admin_write" ON storage.objects
  FOR ALL TO authenticated
  USING (
    bucket_id = 'reimbursement-receipts' AND
    EXISTS (SELECT 1 FROM public.user_roles WHERE user_id = auth.uid() AND role = 'admin')
  )
  WITH CHECK (
    bucket_id = 'reimbursement-receipts' AND
    EXISTS (SELECT 1 FROM public.user_roles WHERE user_id = auth.uid() AND role = 'admin')
  );

COMMIT;

NOTIFY pgrst, 'reload schema';
