-- Evaluation Compliance — make `apply_eval_visits` episode-aware
-- =====================================================================
-- Migration 16's `apply_eval_visits` matches on (patient_id, service)
-- only. When a patient has multiple referrals over time (returning
-- patient), the eval visit from a PRIOR episode gets attached to the
-- current row — producing nonsense like "PTE done 4/8 — synced in 6.6h"
-- on a row whose referral date is 6/1.
--
-- The Patient Visits CSV includes "Start of episode" per visit, so we
-- can disambiguate. This migration:
--   1. Cleans up rows where the attached eval visit clearly belongs to
--      a prior episode (eval_visit_date < episode_start_date).
--   2. Replaces apply_eval_visits with an episode-aware version that
--      matches on (patient_id, service, episode_start_date).
--
-- The JS-side aggregation in compliance.html is updated in parallel so
-- the rows passed in carry episode_start_date.
--
-- Idempotent — safe to re-run. Step 1 only affects rows that haven't
-- already been re-imported with the fixed code.

BEGIN;

-- ─── 1. One-shot cleanup of mismatched eval visits ──────────────────────
-- Wipe eval_* fields whenever the recorded eval_visit_date falls BEFORE
-- the row's own episode_start_date — that visit clearly belonged to a
-- prior referral. Also revert sync_status to 'no_evaluation' for those
-- rows so the UI shows the right state until the user re-imports.
UPDATE public.evaluation_compliance_items
SET eval_visit_date         = NULL,
    eval_visit_type         = NULL,
    eval_visit_clinician    = NULL,
    eval_note_completed_at  = NULL,
    eval_completion_hours   = NULL,
    eval_visit_id           = NULL,
    sync_status             = 'no_evaluation'
WHERE eval_visit_date IS NOT NULL
  AND episode_start_date IS NOT NULL
  AND eval_visit_date < episode_start_date;

-- Same idea for re-eval (less common but worth scrubbing).
UPDATE public.evaluation_compliance_items
SET reeval_visit_date        = NULL,
    reeval_note_completed_at = NULL
WHERE reeval_visit_date IS NOT NULL
  AND episode_start_date IS NOT NULL
  AND reeval_visit_date < episode_start_date;

-- ─── 2. Replace apply_eval_visits with episode-aware version ────────────
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
      episode_start_date       DATE,   -- NEW: per-visit "Start of episode" from the CSV
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
      END
    FROM src s
    WHERE e.patient_id         = s.patient_id
      AND e.service            = s.service
      AND e.episode_start_date = s.episode_start_date    -- NEW: episode-aware
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
