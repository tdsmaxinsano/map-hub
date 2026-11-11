-- ════════════════════════════════════════════════════════════════════
-- 93 · Clinician review meetings + action items
--
-- Territory Planner gets a 📝 Review meetings card: meeting notes per
-- clinician plus action items (optional due date). Open items surface
-- in Roster Review (per-row 📋 badge, "Open tasks" filter, and an
-- all-clinicians open-task list).
--
-- INTERNAL notes: admins + editors only. Clinician-role users (who can
-- view their own Territory Planner) cannot read these rows. Idempotent.
-- ════════════════════════════════════════════════════════════════════
BEGIN;

CREATE TABLE IF NOT EXISTS public.clinician_review_meetings (
  id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  clinician_id      UUID NOT NULL REFERENCES public.clinician_v2(id) ON DELETE CASCADE,
  meeting_date      DATE NOT NULL DEFAULT CURRENT_DATE,
  notes             TEXT,
  created_by        UUID,
  created_by_email  TEXT,
  created_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at        TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.clinician_review_tasks (
  id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  clinician_id      UUID NOT NULL REFERENCES public.clinician_v2(id) ON DELETE CASCADE,
  meeting_id        UUID REFERENCES public.clinician_review_meetings(id) ON DELETE SET NULL,
  title             TEXT NOT NULL,
  due_date          DATE,
  status            TEXT NOT NULL DEFAULT 'open' CHECK (status IN ('open', 'done')),
  done_at           TIMESTAMPTZ,
  done_by           UUID,
  created_by        UUID,
  created_by_email  TEXT,
  created_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at        TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS clinician_review_meetings_cid_idx
  ON public.clinician_review_meetings (clinician_id, meeting_date DESC);
CREATE INDEX IF NOT EXISTS clinician_review_tasks_open_idx
  ON public.clinician_review_tasks (status, clinician_id);

ALTER TABLE public.clinician_review_meetings ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.clinician_review_tasks    ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "crm_staff_all" ON public.clinician_review_meetings;
CREATE POLICY "crm_staff_all" ON public.clinician_review_meetings
  FOR ALL TO authenticated
  USING (EXISTS (SELECT 1 FROM public.user_roles
                 WHERE user_id = auth.uid() AND role IN ('admin', 'editor')))
  WITH CHECK (EXISTS (SELECT 1 FROM public.user_roles
                      WHERE user_id = auth.uid() AND role IN ('admin', 'editor')));

DROP POLICY IF EXISTS "crt_staff_all" ON public.clinician_review_tasks;
CREATE POLICY "crt_staff_all" ON public.clinician_review_tasks
  FOR ALL TO authenticated
  USING (EXISTS (SELECT 1 FROM public.user_roles
                 WHERE user_id = auth.uid() AND role IN ('admin', 'editor')))
  WITH CHECK (EXISTS (SELECT 1 FROM public.user_roles
                      WHERE user_id = auth.uid() AND role IN ('admin', 'editor')));

NOTIFY pgrst, 'reload schema';

COMMIT;
