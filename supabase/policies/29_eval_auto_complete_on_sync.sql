-- Evaluation Compliance — auto-promote category to 'Completed' on sync
-- =====================================================================
-- The visits-import RPC (migration 16, episode-aware in migration 28)
-- auto-flips sync_status to 'synced' when the eval visit + completed
-- note are found in the Patient Visits CSV. But it never touched
-- `category` — so rows could sit in Issues / To Sync / No Sched / etc.
-- forever even after their eval was done and synced.
--
-- This migration:
--   1. One-shot cleanup — every row where sync_status='synced' and
--      category != 'Hold/Hospital' (and not already 'Completed') jumps
--      to 'Completed'. Clears the backlog of stale "needs attention"
--      entries.
--   2. Replaces apply_eval_visits so future imports auto-promote
--      category in the same CASE expression that sets sync_status.
--
-- Hold/Hospital is preserved deliberately — that category means the
-- patient is currently off-service, and the sync may be from a prior
-- eval that's still on file. Admin should re-categorize manually
-- when they come back.
--
-- Idempotent — safe to re-run.

BEGIN;

-- ─── 1. One-shot backfill ───────────────────────────────────────────────
UPDATE public.evaluation_compliance_items
SET category = 'Completed'
WHERE sync_status = 'synced'
  AND category NOT IN ('Hold/Hospital', 'Completed');

-- ─── 2. Replace apply_eval_visits with category-aware variant ───────────
CREATE OR REPLACE FUNCTION public.apply_eval_visits(rows jsonb)
RETURNS INTEGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE n INT;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM user_roles ur
                 WHERE ur.user_id = auth.uid() AND ur.role IN ('admin','editor')) THEN
    RAISE EXCEPTION 'Only admin/editor may apply visits data';
  END IF;

  WITH src AS (
    SELECT * FROM jsonb_to_recordset(rows) AS x(
      patient_id               TEXT,
      service                  TEXT,
      episode_start_date       DATE,
      eval_visit_date          DATE,
      eval_visit_type          TEXT,
      eval_visit_clinician     TEXT,
      eval_note_completed_at   TIMESTAMPTZ,
      eval_completion_hours    NUMERIC,
      eval_visit_id            TEXT,
      reeval_visit_date        DATE,
      reeval_note_completed_at TIMESTAMPTZ,
      last_visit_actual_date   DATE
    )
  ),
  upd AS (
    UPDATE evaluation_compliance_items e SET
      eval_visit_date          = s.eval_visit_date,
      eval_visit_type          = s.eval_visit_type,
      eval_visit_clinician     = s.eval_visit_clinician,
      eval_note_completed_at   = s.eval_note_completed_at,
      eval_completion_hours    = s.eval_completion_hours,
      eval_visit_id            = s.eval_visit_id,
      reeval_visit_date        = s.reeval_visit_date,
      reeval_note_completed_at = s.reeval_note_completed_at,
      last_visit_actual_date   = s.last_visit_actual_date,
      visits_imported_at       = now(),
      sync_status = CASE
        WHEN s.eval_visit_date IS NOT NULL AND s.eval_note_completed_at IS NOT NULL
          THEN 'synced'
        WHEN s.eval_visit_date IS NOT NULL AND s.eval_note_completed_at IS NULL
          THEN 'eval_done_not_synced'
        ELSE e.sync_status
      END,
      category = CASE
        -- Auto-promote to Completed when this import sets sync_status to
        -- 'synced'. Preserve Hold/Hospital (patient off-service —
        -- prior eval being on file isn't the same as work-done).
        WHEN s.eval_visit_date IS NOT NULL
         AND s.eval_note_completed_at IS NOT NULL
         AND e.category NOT IN ('Hold/Hospital', 'Completed')
          THEN 'Completed'
        ELSE e.category
      END
    FROM src s
    WHERE e.patient_id         = s.patient_id
      AND e.service            = s.service
      AND e.episode_start_date = s.episode_start_date
      AND NOT e.is_archived
    RETURNING 1
  )
  SELECT count(*) INTO n FROM upd;

  RETURN n;
END $$;

REVOKE ALL ON FUNCTION public.apply_eval_visits(JSONB) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.apply_eval_visits(JSONB) TO authenticated;

COMMIT;

NOTIFY pgrst, 'reload schema';
