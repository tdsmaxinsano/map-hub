-- ZIP coverage revisions — track TherapyBoss coverage changes per import
-- =====================================================================
-- The ZIP Coverage import is replace-all per matched clinician, so the
-- portal had no memory of what changed: remove ZIPs in TB (the move /
-- won't-serve workflows), re-import, and the old set is simply gone.
-- This records ONE revision row per clinician per import WHERE THE SET
-- ACTUALLY CHANGED: the full before/after snapshots plus the computed
-- added[] / removed[] diff, stamped who + when + which import batch.
--
-- Written by the Map's ZIP Coverage importer (diff computed client-side
-- around the existing delete→insert, non-fatal if this table is absent).
-- Read by the Territory Planner's "📜 Coverage changes" history under
-- the TB Loaded ZIPs card.
--
-- RLS: SELECT authenticated; writes admin+editor (the import itself is
-- editor+ per the Bulk Import access rules). Idempotent — safe to
-- re-run. Run after 58_zip_places.sql.

BEGIN;

CREATE TABLE IF NOT EXISTS public.clinician_zip_coverage_revisions (
  id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  clinician_id     UUID NOT NULL REFERENCES public.clinician_v2(id) ON DELETE CASCADE,
  import_batch_id  UUID,
  zips_before      TEXT[] NOT NULL DEFAULT '{}',
  zips_after       TEXT[] NOT NULL DEFAULT '{}',
  added            TEXT[] NOT NULL DEFAULT '{}',
  removed          TEXT[] NOT NULL DEFAULT '{}',
  changed_by_email TEXT,
  changed_at       TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_zip_cov_rev_clinician
  ON public.clinician_zip_coverage_revisions (clinician_id, changed_at DESC);

COMMENT ON TABLE public.clinician_zip_coverage_revisions IS
  'One row per clinician per ZIP Coverage import where the declared set changed — before/after snapshots + added/removed diff. Audit trail of TherapyBoss coverage edits.';

ALTER TABLE public.clinician_zip_coverage_revisions ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "zip_cov_rev_select_auth"        ON public.clinician_zip_coverage_revisions;
DROP POLICY IF EXISTS "zip_cov_rev_write_editor_admin" ON public.clinician_zip_coverage_revisions;

CREATE POLICY "zip_cov_rev_select_auth" ON public.clinician_zip_coverage_revisions
  FOR SELECT TO authenticated USING (true);

CREATE POLICY "zip_cov_rev_write_editor_admin" ON public.clinician_zip_coverage_revisions
  FOR ALL TO authenticated
  USING      (EXISTS (SELECT 1 FROM public.user_roles ur
                      WHERE ur.user_id = auth.uid() AND ur.role IN ('admin','editor')))
  WITH CHECK (EXISTS (SELECT 1 FROM public.user_roles ur
                      WHERE ur.user_id = auth.uid() AND ur.role IN ('admin','editor')));

COMMIT;

NOTIFY pgrst, 'reload schema';
