-- ════════════════════════════════════════════════════════════════════
-- 72 · Clinician payment delivery — add 'office_pickup'
--
-- Some clinicians pick their check up at the office instead of having
-- it mailed. payment_delivery (migration 25) gains a 4th value:
--   'paper_check'    → displayed as 📭 Mailed Check (relabel only —
--                      stored value unchanged, no data rewrite)
--   'office_pickup'  → displayed as 🏢 Office Pickup (NEW)
--   'direct_deposit' / 'zelle' unchanged.
--
-- Idempotent. Run from the SQL editor BEFORE deploying the matching
-- client (the Roster dropdown writes the new value).
-- ════════════════════════════════════════════════════════════════════
BEGIN;

ALTER TABLE public.clinician_profiles
  DROP CONSTRAINT IF EXISTS clinician_profiles_payment_delivery_check;
ALTER TABLE public.clinician_profiles
  ADD CONSTRAINT clinician_profiles_payment_delivery_check
  CHECK (payment_delivery IN ('paper_check', 'office_pickup', 'direct_deposit', 'zelle'));

NOTIFY pgrst, 'reload schema';

COMMIT;
