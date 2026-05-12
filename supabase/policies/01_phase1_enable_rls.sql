-- Phase 1 RLS: enable RLS on every table, allow authenticated users full access.
-- Anonymous (anon role) gets nothing. Logged-in portal users keep working as today.
--
-- Run in Supabase Dashboard -> SQL Editor.
-- Wrapped in a transaction so a partial failure rolls back automatically.
-- Idempotent: re-running drops and recreates the phase1_authenticated_all policy.

BEGIN;

DO $$
DECLARE
  tbl text;
  tables text[] := ARRAY[
    'clinician_v2',
    'clinician_profiles',
    'clinician_zip_coverages',
    'clinician_profile_languages',
    'clinician_profile_status_log',
    'clinician_profile_versions',
    'language_options',
    'home_health_agencies',
    'referrals',
    'referral_contacts',
    'user_roles',
    'staff_config',
    'time_entries',
    'time_edit_requests',
    'compliance_items',
    'compliance_imports',
    'therapy_boss_address_geocode_cache',
    'therapy_boss_completed_service_import_batches',
    'therapy_boss_completed_service_import_clinicians',
    'therapy_boss_completed_service_import_rows',
    'therapy_boss_referral_import_batches',
    'therapy_boss_referral_import_rows',
    'therapy_boss_zip_coverage_import_batches'
  ];
BEGIN
  FOREACH tbl IN ARRAY tables LOOP
    EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY', tbl);
    EXECUTE format('DROP POLICY IF EXISTS "phase1_authenticated_all" ON public.%I', tbl);
    EXECUTE format(
      'CREATE POLICY "phase1_authenticated_all" ON public.%I
         FOR ALL
         TO authenticated
         USING (true)
         WITH CHECK (true)',
      tbl
    );
  END LOOP;
END $$;

COMMIT;
