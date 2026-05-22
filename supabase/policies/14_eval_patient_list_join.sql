-- Evaluation Compliance — second-file (Patient List) ingestion
-- =====================================================================
-- Adds the fields that TB's "Patient list" report contains but the
-- "Active services" report doesn't:
--
--   * episode_end_date   — already in schema, now actually gets populated
--   * episode_instructions, service_protocol — TB-managed narrative
--   * hold_since, hold_reason, hold_details — drives Hold/Hospital auto-promo
--
-- Also rebuilds upsert_evaluation_items to accept the new fields AND to
-- auto-promote inbound rows with hold_since IS NOT NULL to
-- category='Hold/Hospital' on INSERT (NOT on UPDATE — user's manual triage
-- always wins).
--
-- Idempotent — safe to re-run.

BEGIN;

-- 1. New columns
ALTER TABLE public.evaluation_compliance_items
  ADD COLUMN IF NOT EXISTS episode_instructions TEXT,
  ADD COLUMN IF NOT EXISTS service_protocol     TEXT,
  ADD COLUMN IF NOT EXISTS hold_since           DATE,
  ADD COLUMN IF NOT EXISTS hold_reason          TEXT,
  ADD COLUMN IF NOT EXISTS hold_details         TEXT;

CREATE INDEX IF NOT EXISTS idx_eval_hold_since
  ON public.evaluation_compliance_items (hold_since)
  WHERE hold_since IS NOT NULL AND NOT is_archived;

-- 2. Rebuilt upsert RPC — accepts the new fields, auto-promotes holds on INSERT
CREATE OR REPLACE FUNCTION public.upsert_evaluation_items(rows jsonb, batch_id uuid)
RETURNS INTEGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE n INT;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM user_roles ur
                 WHERE ur.user_id = auth.uid() AND ur.role IN ('admin','editor')) THEN
    RAISE EXCEPTION 'Only admin/editor may import evaluation items';
  END IF;

  WITH src AS (
    SELECT x.*, row_number() OVER () AS rn
    FROM jsonb_to_recordset(rows) AS x(
      patient_id           TEXT, referral_id          TEXT,
      patient_name         TEXT, episode_start_date   DATE, episode_end_date DATE,
      service              TEXT, home_health_agency   TEXT, tb_clinician_name TEXT,
      referral_date        DATE,
      episode_instructions TEXT, service_protocol     TEXT,
      hold_since           DATE, hold_reason          TEXT, hold_details      TEXT
    )
  ),
  src_dedup AS (
    SELECT DISTINCT ON (patient_id, referral_id)
           patient_id, referral_id, patient_name, episode_start_date, episode_end_date,
           service, home_health_agency, tb_clinician_name, referral_date,
           episode_instructions, service_protocol,
           hold_since, hold_reason, hold_details
    FROM src
    WHERE patient_id IS NOT NULL AND referral_id IS NOT NULL
      AND TRIM(patient_id) <> '' AND TRIM(referral_id) <> ''
    ORDER BY patient_id, referral_id, rn DESC
  ),
  ins AS (
    INSERT INTO evaluation_compliance_items
      (patient_id, referral_id, patient_name, episode_start_date, episode_end_date,
       service, home_health_agency, tb_clinician_name, referral_date,
       episode_instructions, service_protocol,
       hold_since, hold_reason, hold_details,
       category,
       imported_at, import_batch_id)
    SELECT patient_id, referral_id, patient_name, episode_start_date, episode_end_date,
           service, home_health_agency, tb_clinician_name, referral_date,
           episode_instructions, service_protocol,
           hold_since, hold_reason, hold_details,
           -- Auto-promotion on INSERT only: TB hold flag = land directly in
           -- Hold/Hospital triage bucket instead of the intake region.
           CASE WHEN hold_since IS NOT NULL THEN 'Hold/Hospital' ELSE 'Assigned' END,
           now(), batch_id
    FROM src_dedup
    ON CONFLICT (patient_id, referral_id) DO UPDATE
      SET patient_name         = EXCLUDED.patient_name,
          episode_start_date   = EXCLUDED.episode_start_date,
          episode_end_date     = EXCLUDED.episode_end_date,
          service              = EXCLUDED.service,
          home_health_agency   = EXCLUDED.home_health_agency,
          tb_clinician_name    = EXCLUDED.tb_clinician_name,
          referral_date        = EXCLUDED.referral_date,
          episode_instructions = EXCLUDED.episode_instructions,
          service_protocol     = EXCLUDED.service_protocol,
          hold_since           = EXCLUDED.hold_since,
          hold_reason          = EXCLUDED.hold_reason,
          hold_details         = EXCLUDED.hold_details,
          -- NOTE: `category` deliberately NOT in UPDATE SET — preserves
          -- whatever bucket the user has manually triaged the row into.
          imported_at          = now(),
          import_batch_id      = batch_id
    RETURNING 1
  )
  SELECT count(*) INTO n FROM ins;

  RETURN n;
END $$;

REVOKE ALL ON FUNCTION public.upsert_evaluation_items(JSONB, UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.upsert_evaluation_items(JSONB, UUID) TO authenticated;

COMMIT;

-- PostgREST schema cache bust
NOTIFY pgrst, 'reload schema';
