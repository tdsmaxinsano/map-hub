-- Clinician "date loaded" — when each clinician was created in the portal
-- ======================================================================
-- Some clinicians have NO visit history, so the Roster's Hire Date
-- (normally derived from the earliest completed service) is blank and
-- there's no way to tell when they joined — or to find "the clinician
-- that was just loaded". This adds clinician_profiles.loaded_at:
--   * stamped by the Map at true clinician-CREATION time (bulk import
--     Additions Only / Full Initial Load insert branch, and the
--     single-clinician create form) — never on updates or syncs;
--   * shown in Roster Review as a sortable "Date Loaded" column
--     (newest-first = who was just added) and as a "📥 loaded {date}"
--     pill in the Hire Date cell when a clinician has neither an
--     explicit hire date nor any visit-derived one.
--
-- DELIBERATELY NO COLUMN DEFAULT: a DEFAULT now() would (a) stamp every
-- legacy row with this migration's timestamp at ALTER time (wrong
-- data), and (b) wrongly stamp an OLD clinician whose profile row only
-- gets created later by a first-ever edit. Only the explicit client
-- writes on the creation paths set it; legacy rows stay NULL (rendered
-- "—" with an honest tooltip) unless a backfill below finds a real
-- earlier timestamp.
--
-- Best-effort backfills (each guarded — source may not exist; only rows
-- with loaded_at IS NULL are touched):
--   1. clinician_profiles.created_at, if that column exists (the table
--      predates this repo, so its exact shape is unknown);
--   2. the EARLIEST clinician_profile_versions row per clinician
--      (approximates "first profile save").
--
-- clinician_v2 is deliberately untouched — it has never been ALTERed by
-- a migration; per-clinician portal columns live on clinician_profiles
-- (precedents: migrations 07/10/18/26). No RLS change (the existing
-- clinician_profiles policies cover new columns).
--
-- Idempotent — safe to re-run. Run after 62_address_change_queue.sql.

BEGIN;

ALTER TABLE public.clinician_profiles ADD COLUMN IF NOT EXISTS loaded_at TIMESTAMPTZ;

CREATE INDEX IF NOT EXISTS idx_clinician_profiles_loaded_at
  ON public.clinician_profiles (loaded_at DESC NULLS LAST);

COMMENT ON COLUMN public.clinician_profiles.loaded_at IS
  'When this clinician was first created in the portal (stamped by the Map''s creation paths only; NULL = predates tracking, Aug 2026). Drives the Roster Date Loaded column + the 📥 loaded Hire-Date fallback.';

-- Backfill 1: clinician_profiles.created_at → loaded_at (if the column exists).
DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'clinician_profiles'
      AND column_name = 'created_at'
  ) THEN
    EXECUTE 'UPDATE public.clinician_profiles SET loaded_at = created_at WHERE loaded_at IS NULL AND created_at IS NOT NULL';
  END IF;
END $$;

-- Backfill 2: earliest clinician_profile_versions row per clinician
-- (first profile save ≈ earliest known presence in the portal).
DO $$
BEGIN
  IF to_regclass('public.clinician_profile_versions') IS NOT NULL THEN
    EXECUTE '
      UPDATE public.clinician_profiles cp
      SET loaded_at = v.first_seen
      FROM (
        SELECT clinician_id, MIN(created_at) AS first_seen
        FROM public.clinician_profile_versions
        GROUP BY clinician_id
      ) v
      WHERE v.clinician_id = cp.clinician_id
        AND cp.loaded_at IS NULL
        AND v.first_seen IS NOT NULL';
  END IF;
END $$;

COMMIT;

NOTIFY pgrst, 'reload schema';
