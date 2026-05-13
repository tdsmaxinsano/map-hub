-- Roster Review schema additions
-- =================================================================
-- Adds the three columns roster-review.html needs to function:
--   * pause_reason TEXT      — optional reason shown next to Paused
--                              status in the bulk table. Status
--                              transitions still write to the
--                              clinician_profile_status_log audit table.
--   * last_reviewed_at TIMESTAMPTZ  — stamped when a reviewer ticks
--                                     the ✓ Reviewed checkbox.
--   * last_reviewed_by UUID          — auth.uid() of the reviewer.
--
-- All three columns are nullable + additive — existing reads and
-- writes elsewhere in the portal are unaffected. clinician_profiles
-- is already under Phase 1 RLS (authenticated-only), so no policy
-- changes needed.
--
-- Run in Supabase Dashboard -> SQL Editor. Idempotent — safe to re-run.

BEGIN;

ALTER TABLE public.clinician_profiles
  ADD COLUMN IF NOT EXISTS pause_reason TEXT;

ALTER TABLE public.clinician_profiles
  ADD COLUMN IF NOT EXISTS last_reviewed_at TIMESTAMPTZ;

ALTER TABLE public.clinician_profiles
  ADD COLUMN IF NOT EXISTS last_reviewed_by UUID;

-- Index so the "Need Review since X" filter is fast on large rosters.
CREATE INDEX IF NOT EXISTS clinician_profiles_last_reviewed_at_idx
  ON public.clinician_profiles (last_reviewed_at);

COMMIT;
