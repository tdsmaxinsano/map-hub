-- Pause lifecycle alerts — add the "currently on vacation" state
-- =====================================================================
-- Supersedes the list_pause_alerts() body from 11_pause_lifecycle.sql.
--
-- Gap this fixes: the original function only alerted on a pause that was
-- ENDING today or tomorrow (a 0-1 day window). So a clinician who was
-- mid-vacation showed "starts in N days" beforehand, then went SILENT for
-- the whole pause, and only reappeared the day before returning.
--
-- This rewrites branch (1) to surface EVERY currently-paused clinician for
-- the full duration of their pause, with a countdown to their return:
--   * pause_end_date = today        -> 'pause_ending_today'   (🟢 returns today)
--   * pause_end_date = tomorrow     -> 'pause_ending_soon'    (🟢 returns tomorrow)
--   * pause_end_date further out    -> 'pause_active'         (🏖 on vacation, back in N days)
--   * pause_end_date IS NULL        -> 'pause_active'         (🏖 on vacation, no return date)
-- days_offset = pause_end_date - CURRENT_DATE (NULL when no end date).
--
-- Branches (2) pause-starting (0-14 days) and (3) just-returned are carried
-- over UNCHANGED from migration 11 — so running this one migration also
-- delivers the 14-day "starts in N days" window if an older 3-day version of
-- the function is still deployed.
--
-- SECURITY DEFINER so editors + readonly see the board (read-only data).
-- Idempotent — CREATE OR REPLACE; safe to re-run.

BEGIN;

CREATE OR REPLACE FUNCTION public.list_pause_alerts()
RETURNS TABLE(
  alert_type        TEXT,
  clinician_id      UUID,
  clinician_name    TEXT,
  discipline        TEXT,
  status            TEXT,
  pause_start_date  DATE,
  pause_end_date    DATE,
  pause_reason      TEXT,
  days_offset       INTEGER,    -- - = past, + = future, 0 = today, NULL = no end date
  changed_at        TIMESTAMPTZ
)
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
  -- (1) Currently paused — surfaced for the WHOLE pause with a return
  -- countdown. Ending today/tomorrow keep their dedicated types (green
  -- "returns" cards); everything else (incl. open-ended pauses) is
  -- 'pause_active' (🏖 on vacation). Overdue rows (end < today, still
  -- Paused) are excluded — the auto-transition Edge Function flips those.
  SELECT
    CASE
      WHEN p.pause_end_date = CURRENT_DATE         THEN 'pause_ending_today'
      WHEN p.pause_end_date = CURRENT_DATE + 1     THEN 'pause_ending_soon'
      ELSE 'pause_active'
    END AS alert_type,
    v.id           AS clinician_id,
    v.name         AS clinician_name,
    v.discipline,
    p.status,
    p.pause_start_date,
    p.pause_end_date,
    p.pause_reason,
    (p.pause_end_date - CURRENT_DATE)::INTEGER AS days_offset,
    NULL::TIMESTAMPTZ AS changed_at
  FROM public.clinician_v2 v
  JOIN public.clinician_profiles p ON p.clinician_id = v.id
  WHERE p.status = 'Paused'
    AND (p.pause_end_date IS NULL OR p.pause_end_date >= CURRENT_DATE)

  UNION ALL

  -- (2) Pause starting in 0-14 days (active, start_date in next 2 weeks).
  -- Widened from the original 3-day window so coverage/coordination has
  -- enough lead time to plan around scheduled vacations.
  SELECT
    CASE WHEN p.pause_start_date = CURRENT_DATE
         THEN 'pause_starting_today' ELSE 'pause_starting_soon' END,
    v.id, v.name, v.discipline, p.status,
    p.pause_start_date, p.pause_end_date, p.pause_reason,
    (p.pause_start_date - CURRENT_DATE)::INTEGER,
    NULL::TIMESTAMPTZ
  FROM public.clinician_v2 v
  JOIN public.clinician_profiles p ON p.clinician_id = v.id
  WHERE p.status = 'Active'
    AND p.pause_start_date IS NOT NULL
    AND p.pause_start_date BETWEEN CURRENT_DATE AND CURRENT_DATE + INTERVAL '14 days'

  UNION ALL

  -- (3) Just-returned (Auto-transition log entry within last 5 days)
  SELECT
    'just_returned',
    v.id, v.name, v.discipline, p.status,
    p.pause_start_date, p.pause_end_date, p.pause_reason,
    -((CURRENT_DATE - sl.changed_at::date))::INTEGER,
    sl.changed_at
  FROM public.clinician_profile_status_log sl
  JOIN public.clinician_v2 v ON v.id = sl.clinician_id
  JOIN public.clinician_profiles p ON p.clinician_id = sl.clinician_id
  WHERE sl.reason = 'Auto-transition: pause end date passed'
    AND sl.changed_at > now() - INTERVAL '5 days'

  ORDER BY days_offset NULLS LAST, clinician_name;
$$;

REVOKE ALL ON FUNCTION public.list_pause_alerts() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.list_pause_alerts() TO authenticated;

COMMIT;
