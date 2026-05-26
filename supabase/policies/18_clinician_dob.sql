-- Clinician DOB + birthday alerts
-- =====================================================================
-- Adds `dob DATE` to clinician_profiles so the Map Bulk Import can carry
-- birthday data into the portal, then drives a new "🎂 birthdays this
-- week" surface on the Home page News & Alerts board.
--
-- Schema additions:
--   * clinician_profiles.dob DATE                — source of truth
--   * idx_clinician_profiles_dob_md              — month*100+day index
--     (allows fast "birthday in next N days" lookups without exposing
--     the year and without a function on the date itself)
--
-- New RPC:
--   * list_birthday_alerts() — returns one row per active/paused clinician
--     whose birthday is today or tomorrow (2-day window per user spec).
--
-- Idempotent — safe to re-run.

BEGIN;

ALTER TABLE public.clinician_profiles
  ADD COLUMN IF NOT EXISTS dob DATE;

CREATE INDEX IF NOT EXISTS idx_clinician_profiles_dob_md
  ON public.clinician_profiles
  ((EXTRACT(MONTH FROM dob)::INT * 100 + EXTRACT(DAY FROM dob)::INT))
  WHERE dob IS NOT NULL;

-- RPC: birthday alerts for the Home page News & Alerts board.
-- Window: day-of (0) + day-before (1). Active + Paused only (excludes Inactive).
CREATE OR REPLACE FUNCTION public.list_birthday_alerts()
RETURNS TABLE(
  alert_type     TEXT,        -- birthday_today | birthday_tomorrow
  clinician_id   UUID,
  clinician_name TEXT,
  discipline     TEXT,
  status         TEXT,
  dob            DATE,
  birthday_iso   DATE,        -- this calendar year's birthday date
  days_until     INTEGER,     -- 0 (today) or 1 (tomorrow)
  age_turning    INTEGER
)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  yr INT := EXTRACT(YEAR FROM CURRENT_DATE);
BEGIN
  RETURN QUERY
  WITH src AS (
    SELECT
      v.id   AS cid,
      v.name AS cname,
      v.discipline AS disc,
      p.status AS sstatus,
      p.dob AS sdob,
      -- LEAST(..., 28) handles Feb 29 leap-day birthdays gracefully — they
      -- surface as Feb 28 in non-leap years.
      MAKE_DATE(yr, EXTRACT(MONTH FROM p.dob)::INT, LEAST(EXTRACT(DAY FROM p.dob)::INT, 28)) AS this_yr_bday
    FROM clinician_v2 v
    JOIN clinician_profiles p ON p.clinician_id = v.id
    WHERE p.dob IS NOT NULL
      -- Active + Paused only; exclude Inactive (terminated)
      AND COALESCE(p.status, '') <> 'Inactive'
  )
  SELECT
    CASE WHEN src.this_yr_bday = CURRENT_DATE THEN 'birthday_today' ELSE 'birthday_tomorrow' END,
    src.cid, src.cname, src.disc, src.sstatus, src.sdob, src.this_yr_bday,
    (src.this_yr_bday - CURRENT_DATE)::INTEGER,
    (yr - EXTRACT(YEAR FROM src.sdob)::INT)::INTEGER
  FROM src
  WHERE (src.this_yr_bday - CURRENT_DATE) BETWEEN 0 AND 1
  ORDER BY src.this_yr_bday, src.cname;
END $$;

REVOKE ALL ON FUNCTION public.list_birthday_alerts() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.list_birthday_alerts() TO authenticated;

-- RPC: birthdays in a specific calendar month — drives the Home page
-- "🎂 Birthdays this month →" drawer. Returns every Active+Paused
-- clinician with a birthday in target_month, sorted by day. days_offset
-- is negative for past dates this month (already happened), 0 for today,
-- positive for upcoming.
CREATE OR REPLACE FUNCTION public.list_birthdays_in_month(target_year INT, target_month INT)
RETURNS TABLE(
  clinician_id   UUID,
  clinician_name TEXT,
  discipline     TEXT,
  status         TEXT,
  birthday_iso   DATE,
  days_offset    INTEGER,
  age_turning    INTEGER
)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  RETURN QUERY
  WITH src AS (
    -- CTE column aliases differ from RETURNS TABLE column names to avoid
    -- the plpgsql "ambiguous column reference" trap (CTE col vs. OUT param).
    SELECT
      v.id         AS cid,
      v.name       AS cname,
      v.discipline AS disc,
      p.status     AS sstatus,
      p.dob        AS sdob,
      -- LEAST(..., 28) keeps Feb 29 birthdays on Feb 28 in non-leap years.
      MAKE_DATE(target_year, EXTRACT(MONTH FROM p.dob)::INT, LEAST(EXTRACT(DAY FROM p.dob)::INT, 28)) AS bday
    FROM clinician_v2 v
    JOIN clinician_profiles p ON p.clinician_id = v.id
    WHERE p.dob IS NOT NULL
      AND EXTRACT(MONTH FROM p.dob)::INT = target_month
      AND COALESCE(p.status, '') <> 'Inactive'
  )
  SELECT
    src.cid, src.cname, src.disc, src.sstatus, src.bday,
    (src.bday - CURRENT_DATE)::INTEGER,
    (target_year - EXTRACT(YEAR FROM src.sdob)::INT)::INTEGER
  FROM src
  ORDER BY src.bday, src.cname;
END $$;

REVOKE ALL ON FUNCTION public.list_birthdays_in_month(INT, INT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.list_birthdays_in_month(INT, INT) TO authenticated;

COMMIT;

NOTIFY pgrst, 'reload schema';
