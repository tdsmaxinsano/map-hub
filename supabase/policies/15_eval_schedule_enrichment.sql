-- Evaluation Compliance — Scheduled Appointments enrichment (Phase 2 import)
-- =====================================================================
-- The two-file base import (Active Services + Patient List) gives us the
-- universe of active patients. This third file — TB's "Scheduled
-- appointments" CSV — enriches each row with:
--
--   * next_eval_date / activity / clinician / confirmed / appt_id / note
--   * last_eval_attempted (latest PAST eval, for missed-eval detection)
--   * scheduled_appt_count (total future appointments)
--   * schedule_imported_at (timestamp marker)
--
-- The new RPC `update_eval_schedule_info` ONLY UPDATES existing rows —
-- it doesn't insert. Matches on (patient_id, service). If a Scheduled
-- Appointments row has no corresponding evaluation_compliance_items row,
-- it's silently skipped (we don't want phantom evals showing up in the
-- triage queue).
--
-- Company SLA rules referenced by the UI (not enforced in SQL):
--   * Schedule eval within 24 hrs of referral
--   * Visit within 48 hrs of referral
--   * Sync the note within 48 hrs of the visit
--
-- Idempotent — safe to re-run.

BEGIN;

ALTER TABLE public.evaluation_compliance_items
  ADD COLUMN IF NOT EXISTS next_eval_date        DATE,
  ADD COLUMN IF NOT EXISTS next_eval_activity    TEXT,
  ADD COLUMN IF NOT EXISTS next_eval_clinician   TEXT,
  ADD COLUMN IF NOT EXISTS next_eval_confirmed   BOOLEAN,
  ADD COLUMN IF NOT EXISTS next_eval_appt_id     TEXT,
  ADD COLUMN IF NOT EXISTS next_eval_note        TEXT,
  ADD COLUMN IF NOT EXISTS last_eval_attempted   DATE,
  ADD COLUMN IF NOT EXISTS scheduled_appt_count  INTEGER,
  ADD COLUMN IF NOT EXISTS schedule_imported_at  TIMESTAMPTZ;

CREATE INDEX IF NOT EXISTS idx_eval_next_eval_date
  ON public.evaluation_compliance_items (next_eval_date)
  WHERE next_eval_date IS NOT NULL AND NOT is_archived;

CREATE INDEX IF NOT EXISTS idx_eval_missing_eval
  ON public.evaluation_compliance_items (patient_id)
  WHERE next_eval_date IS NULL AND NOT is_archived;

-- RPC: update existing rows with scheduling info. Matches on
-- (patient_id, service) so PT and OT episodes for the same patient stay
-- distinct. Returns count of rows actually updated.
CREATE OR REPLACE FUNCTION public.update_eval_schedule_info(rows jsonb)
RETURNS INTEGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE n INT;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM user_roles ur
                 WHERE ur.user_id = auth.uid() AND ur.role IN ('admin','editor')) THEN
    RAISE EXCEPTION 'Only admin/editor may update schedule info';
  END IF;

  WITH src AS (
    SELECT * FROM jsonb_to_recordset(rows) AS x(
      patient_id            TEXT,
      service               TEXT,
      next_eval_date        DATE,
      next_eval_activity    TEXT,
      next_eval_clinician   TEXT,
      next_eval_confirmed   BOOLEAN,
      next_eval_appt_id     TEXT,
      next_eval_note        TEXT,
      last_eval_attempted   DATE,
      scheduled_appt_count  INTEGER
    )
  ),
  upd AS (
    UPDATE evaluation_compliance_items e SET
      next_eval_date        = s.next_eval_date,
      next_eval_activity    = s.next_eval_activity,
      next_eval_clinician   = s.next_eval_clinician,
      next_eval_confirmed   = s.next_eval_confirmed,
      next_eval_appt_id     = s.next_eval_appt_id,
      next_eval_note        = s.next_eval_note,
      last_eval_attempted   = s.last_eval_attempted,
      scheduled_appt_count  = s.scheduled_appt_count,
      schedule_imported_at  = now()
    FROM src s
    WHERE e.patient_id = s.patient_id
      AND e.service    = s.service
      AND NOT e.is_archived
    RETURNING 1
  )
  SELECT count(*) INTO n FROM upd;

  RETURN n;
END $$;

REVOKE ALL ON FUNCTION public.update_eval_schedule_info(JSONB) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.update_eval_schedule_info(JSONB) TO authenticated;

COMMIT;

NOTIFY pgrst, 'reload schema';
