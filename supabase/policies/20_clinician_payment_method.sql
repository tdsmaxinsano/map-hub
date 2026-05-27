-- Clinician payment-method tag — drives the Payroll → Export grouping
-- =====================================================================
-- Each clinician is paid via one of four channels. The default is "check"
-- (accounting creates a bill in QB, user generates check from bill — the
-- existing workflow). Direct deposit / Zelle / W-2 are explicit opt-ins
-- per clinician.
--
-- Schema:
--   * payment_method TEXT DEFAULT 'check' with CHECK constraint
--
-- UI:
--   * Roster Review gets a new "Pay Method" column (default hidden,
--     opt-in via Columns ▾ picker)
--   * Inline dropdown per row writes to this column
--
-- Phase 3 (export to accounting) reads this column to split the audit
-- payload into per-method exports:
--   * 'check'           → QB IIF / CSV for bills (default — most clinicians)
--   * 'direct_deposit'  → ACH file or bank transfer list
--   * 'zelle'           → manual list with name + total
--   * 'w2'              → QB Payroll import file
--
-- Idempotent — safe to re-run.

BEGIN;

ALTER TABLE public.clinician_profiles
  ADD COLUMN IF NOT EXISTS payment_method TEXT NOT NULL DEFAULT 'check';

-- CHECK constraint enforces the four allowed values. Add later via ALTER
-- if more methods are needed.
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'clinician_profiles_payment_method_check'
  ) THEN
    ALTER TABLE public.clinician_profiles
      ADD CONSTRAINT clinician_profiles_payment_method_check
      CHECK (payment_method IN ('check', 'direct_deposit', 'zelle', 'w2'));
  END IF;
END $$;

-- Index for export-grouping queries (Phase 3 will GROUP BY payment_method)
CREATE INDEX IF NOT EXISTS idx_clinician_profiles_payment_method
  ON public.clinician_profiles (payment_method);

COMMIT;

NOTIFY pgrst, 'reload schema';
