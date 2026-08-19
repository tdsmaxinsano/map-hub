-- Clinician ZIP plans — the "therapist moved" staged-territory workflow
-- =====================================================================
-- When a therapist moves, staff set the profile's "Ignore History Before"
-- cutoff and stage a TARGET ZIP list on the Territory Planner: which
-- TB-declared ZIPs to drop (old area) and which to add (new area). The
-- actual change still happens in TherapyBoss (source of truth) — the
-- portal stages intent, and the planner diffs declared-vs-target live so
-- the next ZIP Coverage import visibly confirms the move (the same
-- philosophy as the Proposed Eval workflow).
--
--   clinician_zip_plans — ONE active plan per clinician (PK clinician_id;
--   upsert to restage, DELETE = completed/discarded). target_zips is the
--   intended full declared-ZIP list after the move.
--
-- Stored in a dedicated table (not clinician_profiles.tags) deliberately:
-- write access is enforced at the DB level (admin+editor), and the map's
-- profile save rebuilds the whole tags object from its own cache — a tags
-- blob could be silently clobbered by a stale map tab.
--
-- RLS: SELECT for any authenticated user; writes admin+editor (mirrors
-- 12_evaluation_compliance.sql). Idempotent — safe to re-run.
-- Run after 54_company_renewals.sql.

BEGIN;

CREATE TABLE IF NOT EXISTS public.clinician_zip_plans (
  clinician_id  UUID PRIMARY KEY REFERENCES public.clinician_v2(id) ON DELETE CASCADE,
  target_zips   TEXT[] NOT NULL,
  note          TEXT,
  set_by_email  TEXT,
  set_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.clinician_zip_plans IS
  'Staged target ZIP list per clinician (Territory Planner "therapist moved" workflow). TB stays source of truth — the planner diffs declared vs target until the ZIP import converges, then the row is deleted.';

ALTER TABLE public.clinician_zip_plans ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "zip_plans_select_auth"        ON public.clinician_zip_plans;
DROP POLICY IF EXISTS "zip_plans_write_editor_admin" ON public.clinician_zip_plans;

CREATE POLICY "zip_plans_select_auth" ON public.clinician_zip_plans
  FOR SELECT TO authenticated USING (true);

CREATE POLICY "zip_plans_write_editor_admin" ON public.clinician_zip_plans
  FOR ALL TO authenticated
  USING      (EXISTS (SELECT 1 FROM public.user_roles ur
                      WHERE ur.user_id = auth.uid() AND ur.role IN ('admin','editor')))
  WITH CHECK (EXISTS (SELECT 1 FROM public.user_roles ur
                      WHERE ur.user_id = auth.uid() AND ur.role IN ('admin','editor')));

COMMIT;

NOTIFY pgrst, 'reload schema';
