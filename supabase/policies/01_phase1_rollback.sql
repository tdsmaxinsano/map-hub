-- EMERGENCY ROLLBACK: drop the phase1 policy and disable RLS on all phase 1 tables.
-- Use ONLY if the portal breaks for logged-in users right after applying phase 1.
-- This restores the (insecure) pre-phase-1 state.

BEGIN;

DO $$
DECLARE
  tbl text;
  tables text[] := ARRAY[
    'clinician_v2', 'clinician_profiles', 'clinician_zip_coverages',
    'clinician_profile_languages',
    'clinician_profile_status_log', 'clinician_profile_versions',
    'language_options', 'home_health_agencies', 'referrals', 'referral_contacts',
    'user_roles', 'staff_config', 'time_entries', 'time_edit_requests',
    'compliance_items', 'compliance_imports',
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
    EXECUTE format('DROP POLICY IF EXISTS "phase1_authenticated_all" ON public.%I', tbl);
    EXECUTE format('ALTER TABLE public.%I DISABLE ROW LEVEL SECURITY', tbl);
  END LOOP;
END $$;

COMMIT;
