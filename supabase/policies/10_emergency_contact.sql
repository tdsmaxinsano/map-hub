-- Emergency contact fields on clinician_profiles
-- =====================================================================
-- TherapyBoss tracks the clinician's own phone + email (that's the
-- system of record — those are displayed read-only in Roster Review).
-- But TB does NOT track an emergency contact, so we manage that here.
--
-- Three new nullable text columns. No constraints — admin can fill any
-- combination (name only, phone only, all three, etc.). Idempotent.

BEGIN;

ALTER TABLE public.clinician_profiles
  ADD COLUMN IF NOT EXISTS emergency_contact_name     TEXT,
  ADD COLUMN IF NOT EXISTS emergency_contact_phone    TEXT,
  ADD COLUMN IF NOT EXISTS emergency_contact_relation TEXT;

COMMIT;
