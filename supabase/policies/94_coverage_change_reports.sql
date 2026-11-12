-- ════════════════════════════════════════════════════════════════════
-- 94 · Coverage change reports (Territory Planner 📸)
--
-- An engineering-markup style before/after report of a clinician's
-- TherapyBoss ZIP coverage change: the marked-up map image (private
-- coverage-reports bucket) plus the before / after / added / removed
-- lists, built from a clinician_zip_coverage_revisions row (what TB
-- actually changed). Stored every time one is generated; emailing it
-- is optional and manual (send-coverage-report Edge Function), and the
-- row records who it went to and when.
--
-- Admin + editor only. Idempotent.
-- ════════════════════════════════════════════════════════════════════
BEGIN;

CREATE TABLE IF NOT EXISTS public.coverage_change_reports (
  id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  clinician_id      UUID NOT NULL REFERENCES public.clinician_v2(id) ON DELETE CASCADE,
  revision_id       UUID REFERENCES public.clinician_zip_coverage_revisions(id) ON DELETE SET NULL,
  zips_before       TEXT[] NOT NULL DEFAULT '{}',
  zips_after        TEXT[] NOT NULL DEFAULT '{}',
  added             TEXT[] NOT NULL DEFAULT '{}',
  removed           TEXT[] NOT NULL DEFAULT '{}',
  reason            TEXT,
  note              TEXT,
  image_path        TEXT,                 -- coverage-reports bucket object
  created_by        UUID,
  created_by_email  TEXT,
  created_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
  sent_at           TIMESTAMPTZ,
  sent_to           TEXT[] NOT NULL DEFAULT '{}',
  sent_by_email     TEXT
);

CREATE INDEX IF NOT EXISTS coverage_change_reports_cid_idx
  ON public.coverage_change_reports (clinician_id, created_at DESC);

ALTER TABLE public.coverage_change_reports ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "ccr_staff_all" ON public.coverage_change_reports;
CREATE POLICY "ccr_staff_all" ON public.coverage_change_reports
  FOR ALL TO authenticated
  USING (EXISTS (SELECT 1 FROM public.user_roles
                 WHERE user_id = auth.uid() AND role IN ('admin', 'editor')))
  WITH CHECK (EXISTS (SELECT 1 FROM public.user_roles
                      WHERE user_id = auth.uid() AND role IN ('admin', 'editor')));

-- ── Private bucket for the marked-up map images ─────────────────────
INSERT INTO storage.buckets (id, name, public)
VALUES ('coverage-reports', 'coverage-reports', false)
ON CONFLICT (id) DO NOTHING;

DROP POLICY IF EXISTS "covrep_staff_all" ON storage.objects;
CREATE POLICY "covrep_staff_all" ON storage.objects
  FOR ALL TO authenticated
  USING (bucket_id = 'coverage-reports'
         AND EXISTS (SELECT 1 FROM public.user_roles
                     WHERE user_id = auth.uid() AND role IN ('admin', 'editor')))
  WITH CHECK (bucket_id = 'coverage-reports'
              AND EXISTS (SELECT 1 FROM public.user_roles
                          WHERE user_id = auth.uid() AND role IN ('admin', 'editor')));

NOTIFY pgrst, 'reload schema';

COMMIT;
