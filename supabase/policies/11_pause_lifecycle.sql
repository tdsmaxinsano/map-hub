-- Pause / Vacation lifecycle alerts RPC
-- =====================================================================
-- Drives the "📰 News & Alerts" board on the Home page + pause-aware
-- pills in Roster Review + the Map's profile header. Returns one row
-- per active alert with a typed alert_type so the renderer can switch
-- on icon / color / message.
--
-- The companion Edge Function `auto-transition-pauses` flips stale
-- Paused → Active server-side once a day; this RPC reads the result.
--
-- SECURITY DEFINER so editors + readonly users can see the alerts
-- board too (it's read-only data; status edits remain admin/editor
-- via the existing RLS on clinician_profiles).
--
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
  days_offset       INTEGER,    -- - = past, + = future, 0 = today
  changed_at        TIMESTAMPTZ
)
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
  -- (1) Pause ending in 0-1 days (paused, end_date is today or tomorrow)
  SELECT
    CASE WHEN p.pause_end_date = CURRENT_DATE
         THEN 'pause_ending_today' ELSE 'pause_ending_soon' END AS alert_type,
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
    AND p.pause_end_date IS NOT NULL
    AND p.pause_end_date BETWEEN CURRENT_DATE AND CURRENT_DATE + INTERVAL '1 day'

  UNION ALL

  -- (2) Pause starting in 0-3 days (active, start_date in next 3 days)
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
    AND p.pause_start_date BETWEEN CURRENT_DATE AND CURRENT_DATE + INTERVAL '3 days'

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
