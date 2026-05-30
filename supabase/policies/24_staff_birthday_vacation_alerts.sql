-- Office staff birthdays + scheduled vacations on the News & Alerts board
-- =====================================================================
-- Clinicians already surface birthdays (`list_birthday_alerts`) and
-- pause/vacation events (`list_pause_alerts`) on the Home page board.
-- Office staff had no equivalent — admin couldn't see who's about to
-- take time off or whose birthday is coming up.
--
-- This migration:
--   1. Adds `dob DATE` to `staff_config` so admin can record office
--      employees' birthdays from the Time Tracker Settings tab.
--   2. Adds `list_staff_birthday_alerts()` — staff with birthday today
--      or tomorrow (mirrors `list_birthday_alerts` shape).
--   3. Adds `list_staff_vacation_alerts()` — groups consecutive days
--      tagged `absence_kind = 'vacation'` from `time_entries` into
--      single "vacation blocks" per staff, returns blocks that include
--      today or start within the next 14 days. Both clock_in storage
--      and admin pay-period anchors are US Central, so the gap-and-
--      island grouping below operates in `America/Chicago` to keep
--      day boundaries consistent.
--
-- Idempotent — safe to re-run.

BEGIN;

-- ─── Schema ──────────────────────────────────────────────────────────
ALTER TABLE public.staff_config
  ADD COLUMN IF NOT EXISTS dob DATE;

-- Month*100+day index — fast birthday-window queries without exposing year.
CREATE INDEX IF NOT EXISTS idx_staff_config_dob_md
  ON public.staff_config ((EXTRACT(MONTH FROM dob)::INT * 100 + EXTRACT(DAY FROM dob)::INT))
  WHERE dob IS NOT NULL;

-- ─── RPC: staff birthday alerts (today + tomorrow) ───────────────────
CREATE OR REPLACE FUNCTION public.list_staff_birthday_alerts()
RETURNS TABLE(
  alert_type     TEXT,        -- 'staff_birthday_today' | 'staff_birthday_tomorrow'
  staff_id       UUID,
  staff_name     TEXT,
  staff_role     TEXT,        -- 'Office' as a generic label for the renderer
  dob            DATE,
  birthday_iso   DATE,        -- this-year's birthday date (Feb 29 → Feb 28)
  days_until     INTEGER,
  age_turning    INTEGER
)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE yr INT := EXTRACT(YEAR FROM CURRENT_DATE);
BEGIN
  RETURN QUERY
  WITH src AS (
    SELECT
      sc.user_id                                                                  AS staff_id,
      COALESCE(sc.display_name, '(unnamed)')                                      AS staff_name,
      sc.dob,
      MAKE_DATE(yr, EXTRACT(MONTH FROM sc.dob)::INT, LEAST(EXTRACT(DAY FROM sc.dob)::INT, 28)) AS this_yr_bday
    FROM staff_config sc
    WHERE sc.dob IS NOT NULL
      AND COALESCE(sc.is_active, true) = true
  )
  SELECT
    CASE WHEN this_yr_bday = CURRENT_DATE THEN 'staff_birthday_today'
         ELSE 'staff_birthday_tomorrow' END AS alert_type,
    staff_id, staff_name, 'Office'::TEXT AS staff_role,
    dob, this_yr_bday,
    (this_yr_bday - CURRENT_DATE)::INTEGER AS days_until,
    (yr - EXTRACT(YEAR FROM dob)::INT)::INTEGER AS age_turning
  FROM src
  WHERE (this_yr_bday - CURRENT_DATE) BETWEEN 0 AND 1
  ORDER BY this_yr_bday, staff_name;
END $$;

-- ─── RPC: staff scheduled-vacation alerts ────────────────────────────
-- Groups consecutive `absence_kind = 'vacation'` days per staff into
-- single vacation blocks (gap-and-island). Returns blocks that are
-- happening today or starting within the next 14 days.
CREATE OR REPLACE FUNCTION public.list_staff_vacation_alerts()
RETURNS TABLE(
  alert_type        TEXT,        -- 'staff_vacation_active' | 'staff_vacation_today' | 'staff_vacation_soon'
  staff_id          UUID,
  staff_name        TEXT,
  staff_role        TEXT,
  vacation_start    DATE,
  vacation_end      DATE,
  days_until        INTEGER      -- start - today; 0 = starts today, negative = already started
)
LANGUAGE sql SECURITY DEFINER SET search_path = public AS $$
  WITH va AS (
    SELECT
      sc.user_id,
      COALESCE(sc.display_name, '(unnamed)') AS display_name,
      ((te.clock_in AT TIME ZONE 'America/Chicago')::date) AS d
    FROM time_entries te
    JOIN staff_config sc ON sc.user_id = te.user_id
    WHERE te.absence_kind = 'vacation'
      AND te.is_manual    = true
      AND COALESCE(sc.is_active, true) = true
      -- Look back a little so an in-progress block whose start was earlier
      -- this week still surfaces. 30 day look-back is generous.
      AND ((te.clock_in AT TIME ZONE 'America/Chicago')::date) BETWEEN CURRENT_DATE - INTERVAL '30 days' AND CURRENT_DATE + INTERVAL '14 days'
  ),
  numbered AS (
    SELECT
      user_id, display_name, d,
      d - (ROW_NUMBER() OVER (PARTITION BY user_id ORDER BY d))::int AS grp
    FROM va
  ),
  blocks AS (
    SELECT user_id, display_name,
           MIN(d) AS vacation_start,
           MAX(d) AS vacation_end
    FROM numbered
    GROUP BY user_id, display_name, grp
  )
  SELECT
    CASE
      WHEN vacation_start <= CURRENT_DATE AND vacation_end >= CURRENT_DATE THEN 'staff_vacation_active'
      WHEN vacation_start = CURRENT_DATE                                   THEN 'staff_vacation_today'
      ELSE                                                                       'staff_vacation_soon'
    END AS alert_type,
    user_id AS staff_id,
    display_name AS staff_name,
    'Office'::TEXT AS staff_role,
    vacation_start,
    vacation_end,
    (vacation_start - CURRENT_DATE)::int AS days_until
  FROM blocks
  -- Show blocks that are happening now OR start within the next 14 days.
  WHERE (vacation_start <= CURRENT_DATE + 14 AND vacation_end >= CURRENT_DATE)
  ORDER BY vacation_start, display_name;
$$;

REVOKE ALL ON FUNCTION public.list_staff_birthday_alerts() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.list_staff_vacation_alerts() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.list_staff_birthday_alerts() TO authenticated;
GRANT EXECUTE ON FUNCTION public.list_staff_vacation_alerts() TO authenticated;

COMMIT;

NOTIFY pgrst, 'reload schema';
