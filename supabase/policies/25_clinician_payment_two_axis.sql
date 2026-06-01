-- Clinician payment classification — split into two orthogonal axes
-- =====================================================================
-- Migration 20 captured payment as a single value ('check' | 'direct_deposit'
-- | 'zelle' | 'w2'). But in real life payment is two independent axes:
--   * BILLING TYPE — how QuickBooks records it ('bill' = QB bill / paper-
--     check workflow, or 'w2' = W-2 Payroll). Drives Phase 3 export files.
--   * DELIVERY     — how the money actually moves ('paper_check',
--     'direct_deposit', 'zelle'). Drives the Wise/ACH/check generation step.
--
-- A clinician can be (W-2 Payroll + Direct Deposit) OR (QB Bill + DD) OR
-- (QB Bill + Paper Check), etc. — these are independent.
--
-- This migration repurposes the existing `payment_method` column to mean
-- billing type only ('bill'|'w2') and adds a new `payment_delivery` column
-- with the delivery axis. Existing data is migrated transparently — admin
-- can fine-tune any miscategorized rows from Roster Review afterward.
--
-- Idempotent — safe to re-run.

BEGIN;

-- ─── 1. New delivery column ───────────────────────────────────────────
ALTER TABLE public.clinician_profiles
  ADD COLUMN IF NOT EXISTS payment_delivery TEXT NOT NULL DEFAULT 'paper_check';

-- ─── 2. Drop the OLD payment_method CHECK before data migration ───────
-- The legacy constraint enforces payment_method IN ('check','direct_deposit',
-- 'zelle','w2'). Step 3 below sets payment_method='bill' for non-w2 rows,
-- which would otherwise be rejected by the legacy constraint. Drop first,
-- recreate with the new value set in step 4.
ALTER TABLE public.clinician_profiles
  DROP CONSTRAINT IF EXISTS clinician_profiles_payment_method_check;

-- ─── 3. Migrate existing payment_method values to the two-axis model ──
-- One-shot data migration: only runs against rows still carrying a
-- legacy single value. After this runs once, subsequent runs are no-ops.
UPDATE public.clinician_profiles
   SET payment_delivery = CASE payment_method
     WHEN 'check'           THEN 'paper_check'
     WHEN 'direct_deposit'  THEN 'direct_deposit'
     WHEN 'zelle'           THEN 'zelle'
     WHEN 'w2'              THEN 'direct_deposit'     -- best guess; admin can fix per clinician
     ELSE payment_delivery
   END
 WHERE payment_method IN ('check','direct_deposit','zelle','w2');

UPDATE public.clinician_profiles
   SET payment_method = CASE payment_method
     WHEN 'w2' THEN 'w2'
     ELSE 'bill'                                     -- everything else collapses to QB Bill
   END
 WHERE payment_method IN ('check','direct_deposit','zelle','w2');

-- ─── 4. Recreate CHECK constraints with the new value sets ────────────
ALTER TABLE public.clinician_profiles
  ADD CONSTRAINT clinician_profiles_payment_method_check
  CHECK (payment_method IN ('bill','w2'));

ALTER TABLE public.clinician_profiles
  DROP CONSTRAINT IF EXISTS clinician_profiles_payment_delivery_check;
ALTER TABLE public.clinician_profiles
  ADD CONSTRAINT clinician_profiles_payment_delivery_check
  CHECK (payment_delivery IN ('paper_check','direct_deposit','zelle'));

-- ─── 5. Default the bill-type column going forward to 'bill' ──────────
-- Migration 20 set it to 'check' which is no longer valid; reset the
-- column default so new rows land on the right value.
ALTER TABLE public.clinician_profiles
  ALTER COLUMN payment_method SET DEFAULT 'bill';

-- ─── 6. Index for the new delivery axis (Phase 3 export grouping) ────
CREATE INDEX IF NOT EXISTS idx_clinician_profiles_payment_delivery
  ON public.clinician_profiles (payment_delivery);

COMMIT;

NOTIFY pgrst, 'reload schema';
