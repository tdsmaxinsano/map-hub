-- ════════════════════════════════════════════════════════════════════
-- 77 · Close the PUBLIC-grant holdovers on app functions
--
-- Migration 76 revoked DIRECT anon grants; these functions were still
-- executable by the logged-out role via Postgres's implicit PUBLIC
-- grant. Revoke PUBLIC + anon on the app functions and re-grant
-- authenticated + service_role so signed-in behavior is unchanged
-- (is_admin_user may be referenced from policies — the authenticated
-- grant is load-bearing). Trigger functions keep firing regardless
-- (they execute as the table owner).
--
-- pg_trgm extension internals (gtrgm_*, similarity*, …) are left
-- alone on purpose: operator/index plumbing with no data access.
-- Idempotent.
-- ════════════════════════════════════════════════════════════════════
BEGIN;

DO $$
DECLARE f record;
BEGIN
  FOR f IN
    SELECT p.oid::regprocedure AS sig
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.proname IN (
        'list_clinician_last_activity', 'is_admin_user',
        'normalize_agency_name', 'normalize_expense_keyword', 'normalize_payer_name',
        'ecr_touch_updated_at', 'hhac_touch_updated_at', 'pcd_touch_updated_at',
        'enforce_approved_period_lock', 'handle_new_user', 'handle_new_user_staff'
      )
  LOOP
    EXECUTE format('REVOKE EXECUTE ON FUNCTION %s FROM PUBLIC, anon', f.sig);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO authenticated, service_role', f.sig);
  END LOOP;
END $$;

NOTIFY pgrst, 'reload schema';

COMMIT;
