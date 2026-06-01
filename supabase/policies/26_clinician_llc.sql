-- Clinician LLC / business-entity information
-- =====================================================================
-- Some clinicians operate through their own LLC (e.g. "Rafael Therapy
-- Services LLC"). When admin generates the QB Bill / 1099 for them, the
-- "payable to" name on the bill should be the LLC, not the person —
-- and accounting needs the EIN for tax forms.
--
-- Two new columns on clinician_profiles:
--   * llc_name TEXT — free text, displayed as a small "🏢 {name}"
--     sub-line under the clinician name on Map / Roster / Payroll.
--   * llc_ein  TEXT — free text (EIN format is "XX-XXXXXXX" but we
--     keep it free so admin can paste however accounting tracks it).
--     Only displayed in Roster Review (admin reference) — NOT
--     surfaced on the Map or Payroll display lines.
--
-- Both are NULL by default. Idempotent — safe to re-run.

BEGIN;

ALTER TABLE public.clinician_profiles
  ADD COLUMN IF NOT EXISTS llc_name TEXT,
  ADD COLUMN IF NOT EXISTS llc_ein  TEXT;

-- Light index so Phase 3 export "group by payable-to" queries are
-- snappy when grouping by LLC vs. individual. NULLs excluded.
CREATE INDEX IF NOT EXISTS idx_clinician_profiles_llc_name
  ON public.clinician_profiles (llc_name)
  WHERE llc_name IS NOT NULL;

COMMIT;

NOTIFY pgrst, 'reload schema';
