-- ════════════════════════════════════════════════════════════════════
-- 76 · Fix the Supabase security-lint ERRORS (Oct 2026 email)
--
-- A — the three tables Phase 1 (migration 01) missed, flagged
--     "rls_disabled_in_public" / "policy_exists_rls_disabled":
--       · clinician_referrals          → enable RLS + phase1 policy
--       · clinician_territory_versions → enable RLS + phase1 policy
--       · pay_period_adjustments       → enable RLS (its policies
--         "Admin adjustments - all" + "Own adjustments - select"
--         already exist — they were just INERT because RLS was off)
--
-- B — belt-and-braces for the 72 "anon can execute SECURITY DEFINER
--     function" warnings: the logged-out anon role loses EXECUTE on
--     every function in public (and on future ones via default
--     privileges). Logged-in users are untouched — every portal RPC
--     is called with an authenticated session.
--
-- Zero behavior change for logged-in portal users. Idempotent.
-- ════════════════════════════════════════════════════════════════════
BEGIN;

-- ── A1. clinician_referrals + clinician_territory_versions ───────────
-- Same Phase-1 posture as the other 23 core tables: any signed-in
-- portal user, nothing for anon.
ALTER TABLE public.clinician_referrals          ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.clinician_territory_versions ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS phase1_authenticated_all ON public.clinician_referrals;
CREATE POLICY phase1_authenticated_all ON public.clinician_referrals
  FOR ALL TO authenticated USING (true) WITH CHECK (true);

DROP POLICY IF EXISTS phase1_authenticated_all ON public.clinician_territory_versions;
CREATE POLICY phase1_authenticated_all ON public.clinician_territory_versions
  FOR ALL TO authenticated USING (true) WITH CHECK (true);

-- ── A2. pay_period_adjustments ───────────────────────────────────────
-- Its policies already exist (admin everything / staff read own) —
-- enabling RLS is what finally makes them count.
ALTER TABLE public.pay_period_adjustments ENABLE ROW LEVEL SECURITY;

-- ── B. anon can no longer execute any public function ────────────────
-- Most RPCs self-check roles internally, but there is no reason the
-- logged-out role should be able to invoke them at all.
REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA public FROM anon;
ALTER DEFAULT PRIVILEGES IN SCHEMA public REVOKE EXECUTE ON FUNCTIONS FROM anon;

NOTIFY pgrst, 'reload schema';

COMMIT;
