-- ════════════════════════════════════════════════════════════════════
-- 96 · Clinician Profiler — cached AI "Analyst read"
--
-- The Territory Planner's 🧠 Clinician Profile card computes facts
-- (tenure, city/suburb mix, range, shift detection …) in the browser and
-- asks the clinician-profile-ai edge function (Claude) to write a short
-- narrative from those facts ONLY — aggregates, no patient names or
-- addresses. One cached row per clinician; facts_hash tells the UI when
-- the facts changed since the narrative was written (↻ regenerates).
--
-- Read: admin / editor / readonly (internal analysis — NOT the
-- clinician role). Write: admin / editor (the edge function writes with
-- the caller's JWT, so RLS applies). Idempotent.
-- ════════════════════════════════════════════════════════════════════
BEGIN;

CREATE TABLE IF NOT EXISTS public.clinician_ai_profiles (
  clinician_id   UUID PRIMARY KEY REFERENCES public.clinician_v2(id) ON DELETE CASCADE,
  facts_hash     TEXT NOT NULL,
  narrative      TEXT NOT NULL,
  model          TEXT,
  generated_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
  generated_by   UUID
);

ALTER TABLE public.clinician_ai_profiles ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "cap_staff_read" ON public.clinician_ai_profiles;
CREATE POLICY "cap_staff_read" ON public.clinician_ai_profiles
  FOR SELECT TO authenticated
  USING (EXISTS (SELECT 1 FROM public.user_roles
                 WHERE user_id = auth.uid() AND role IN ('admin', 'editor', 'readonly')));

DROP POLICY IF EXISTS "cap_staff_write" ON public.clinician_ai_profiles;
CREATE POLICY "cap_staff_write" ON public.clinician_ai_profiles
  FOR ALL TO authenticated
  USING (EXISTS (SELECT 1 FROM public.user_roles
                 WHERE user_id = auth.uid() AND role IN ('admin', 'editor')))
  WITH CHECK (EXISTS (SELECT 1 FROM public.user_roles
                      WHERE user_id = auth.uid() AND role IN ('admin', 'editor')));

NOTIFY pgrst, 'reload schema';

COMMIT;
