-- Evaluation Compliance — Patient Visits enrichment (Phase 3 import)
-- =====================================================================
-- The third TB report — "Patient visits" — is what actually verifies the
-- eval got done. Adding it lets us:
--
--   * Auto-update sync_status from raw data (no more manual "is it synced?")
--   * Track the 48-hr note-sync SLA (TB's "Completion delay" → hours)
--   * Separate initial-eval tracking (PTE/OTE/STE) from re-eval (PTRE/OTRE/STRE)
--   * Derive a true last_visit_actual_date (replacing TB's stale value)
--
-- New RPC: apply_eval_visits(rows jsonb) — UPDATE-only, matches on
-- (patient_id, service). When an eval visit is found, sync_status is
-- auto-set per these rules:
--   * eval_note_completed_at IS NOT NULL → 'synced'
--   * eval_note_completed_at IS NULL     → 'eval_done_not_synced'
--   * no eval visit at all               → sync_status untouched
--
-- (User-driven sync_status changes are tracked via last_edited_at — but
-- per user instruction we let visit data win here. To override manually,
-- the user just flips the sync dropdown again after import.)
--
-- Idempotent — safe to re-run.

BEGIN;

ALTER TABLE public.evaluation_compliance_items
  -- Initial eval (PTE/OTE/STE)
  ADD COLUMN IF NOT EXISTS eval_visit_date         DATE,
  ADD COLUMN IF NOT EXISTS eval_visit_type         TEXT,
  ADD COLUMN IF NOT EXISTS eval_visit_clinician    TEXT,
  ADD COLUMN IF NOT EXISTS eval_note_completed_at  TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS eval_completion_hours   NUMERIC,
  ADD COLUMN IF NOT EXISTS eval_visit_id           TEXT,

  -- Re-eval (PTRE/OTRE/STRE) — tracked separately
  ADD COLUMN IF NOT EXISTS reeval_visit_date        DATE,
  ADD COLUMN IF NOT EXISTS reeval_note_completed_at TIMESTAMPTZ,

  -- Latest visit of ANY type — replaces Active Services' stale value
  ADD COLUMN IF NOT EXISTS last_visit_actual_date  DATE,

  -- Provenance
  ADD COLUMN IF NOT EXISTS visits_imported_at      TIMESTAMPTZ;

CREATE INDEX IF NOT EXISTS idx_eval_eval_visit_date
  ON public.evaluation_compliance_items (eval_visit_date)
  WHERE eval_visit_date IS NOT NULL AND NOT is_archived;

CREATE INDEX IF NOT EXISTS idx_eval_last_visit_actual
  ON public.evaluation_compliance_items (last_visit_actual_date)
  WHERE last_visit_actual_date IS NOT NULL AND NOT is_archived;

-- RPC: apply visit-derived enrichment. UPDATE-only — matches on
-- (patient_id, service). Auto-derives sync_status when an eval visit
-- is present.
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
      -- Auto-derive sync_status only when there's an eval visit. No visit
      -- means we leave sync_status alone (could be a 'cancelled' or
      -- manually-set value the user wants preserved).
      sync_status = CASE
        WHEN s.eval_visit_date IS NOT NULL AND s.eval_note_completed_at IS NOT NULL
          THEN 'synced'
        WHEN s.eval_visit_date IS NOT NULL AND s.eval_note_completed_at IS NULL
          THEN 'eval_done_not_synced'
        ELSE e.sync_status
      END
    FROM src s
    WHERE e.patient_id = s.patient_id
      AND e.service    = s.service
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
