-- ════════════════════════════════════════════════════════════════════
-- 92 · Parking: Med B / internal rows — pay the clinician, never
-- invoice an agency (e.g. OT under Medicare Part B where the patient
-- was never in TherapyBoss). A no_invoice row closes as soon as its
-- check is exported and is excluded from the invoice export, the
-- needs-invoice stats, and the TB re-match. Idempotent.
-- ════════════════════════════════════════════════════════════════════
BEGIN;

ALTER TABLE public.parking_reimbursements
  ADD COLUMN IF NOT EXISTS no_invoice BOOLEAN NOT NULL DEFAULT FALSE;

NOTIFY pgrst, 'reload schema';

COMMIT;
