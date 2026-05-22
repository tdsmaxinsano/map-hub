-- Evaluation Compliance — add `referral_date` + default new rows to 'Assigned'
-- =====================================================================
-- Reflects the actual workflow from the user's spreadsheet:
--   - New TB rows land in an "Assigned MM/DD/YYYY" bucket (auto-grouped
--     by the TB "Referral date" column).
--   - User then manually hoists rows up into Issues / Hold-Hospital /
--     Re-Evaluation / No Sched / Scheduled-Late Eval / To Sync / Completed.
--
-- Schema deltas:
--   1. `referral_date DATE` — populated from the CSV import; drives the
--      date sub-headers in the Evaluation view's "Intake" region.
--   2. `category` default changes from 'Active' → 'Assigned' so newly
--      inserted rows land in the intake region by default. Existing rows
--      with category='Active' are migrated to 'Assigned' (one-time).
--
-- Idempotent — safe to re-run.

BEGIN;

-- 1. Add referral_date column
ALTER TABLE public.evaluation_compliance_items
  ADD COLUMN IF NOT EXISTS referral_date DATE;

CREATE INDEX IF NOT EXISTS idx_eval_referral_date
  ON public.evaluation_compliance_items (referral_date DESC)
  WHERE NOT is_archived;

-- 2. Change the default category to 'Assigned' for future inserts
ALTER TABLE public.evaluation_compliance_items
  ALTER COLUMN category SET DEFAULT 'Assigned';

-- 3. Migrate any existing rows still on the legacy 'Active' default →
-- 'Assigned' so they appear in the new intake region. Only touches rows
-- that haven't been manually triaged into another bucket.
UPDATE public.evaluation_compliance_items
  SET category = 'Assigned'
  WHERE category = 'Active';

-- 4. Rebuild the upsert RPC to accept + store referral_date.
-- Same dedupe + preserve-user-edits behavior as before, just one extra
-- column shuttled through.
CREATE OR REPLACE FUNCTION public.upsert_evaluation_items(rows JSONB, batch_id UUID)
RETURNS INTEGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE n INT;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM user_roles ur
                 WHERE ur.user_id = auth.uid() AND ur.role IN ('admin','editor')) THEN
    RAISE EXCEPTION 'Only admin/editor may import evaluation items';
  END IF;

  WITH src AS (
    -- ROW_NUMBER over the input order gives us a stable "last occurrence
    -- wins" tiebreaker for the dedupe below. (jsonb_to_recordset output has
    -- no ctid since it's an in-memory rowset, not a real table.)
    SELECT x.*, row_number() OVER () AS rn
    FROM jsonb_to_recordset(rows) AS x(
      patient_id          TEXT, referral_id        TEXT,
      patient_name        TEXT, episode_start_date DATE, episode_end_date DATE,
      service             TEXT, home_health_agency TEXT, tb_clinician_name TEXT,
      referral_date       DATE
    )
  ),
  src_dedup AS (
    SELECT DISTINCT ON (patient_id, referral_id)
           patient_id, referral_id, patient_name, episode_start_date, episode_end_date,
           service, home_health_agency, tb_clinician_name, referral_date
    FROM src
    WHERE patient_id IS NOT NULL AND referral_id IS NOT NULL
      AND TRIM(patient_id) <> '' AND TRIM(referral_id) <> ''
    ORDER BY patient_id, referral_id, rn DESC
  ),
  ins AS (
    INSERT INTO evaluation_compliance_items
      (patient_id, referral_id, patient_name, episode_start_date, episode_end_date,
       service, home_health_agency, tb_clinician_name, referral_date,
       imported_at, import_batch_id)
    SELECT patient_id, referral_id, patient_name, episode_start_date, episode_end_date,
           service, home_health_agency, tb_clinician_name, referral_date,
           now(), batch_id
    FROM src_dedup
    ON CONFLICT (patient_id, referral_id) DO UPDATE
      SET patient_name        = EXCLUDED.patient_name,
          episode_start_date  = EXCLUDED.episode_start_date,
          episode_end_date    = EXCLUDED.episode_end_date,
          service             = EXCLUDED.service,
          home_health_agency  = EXCLUDED.home_health_agency,
          tb_clinician_name   = EXCLUDED.tb_clinician_name,
          referral_date       = EXCLUDED.referral_date,
          imported_at         = now(),
          import_batch_id     = batch_id
    RETURNING 1
  )
  SELECT count(*) INTO n FROM ins;

  RETURN n;
END $$;

REVOKE ALL ON FUNCTION public.upsert_evaluation_items(JSONB, UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.upsert_evaluation_items(JSONB, UUID) TO authenticated;

COMMIT;

-- Reload PostgREST schema cache so the RPC signature change is picked up
-- immediately (otherwise the existing function with old args may stick
-- around in the cache for up to ~10 minutes).
NOTIFY pgrst, 'reload schema';
