-- One-shot repair: recompute corrupt derived start/hire dates
-- =====================================================================
-- Background: a stray value (e.g. "2024" typed into a date cell, or a
-- small count) was read as an Excel serial during a completed-service
-- import and converted to 1905-07-17. That impossibly-early date then
-- won the "earliest service date" reduce that produces each clinician's
-- AUTO start/hire date, stored in clinician_profiles.tags->>'derivedStartDate'.
--
-- PRs #128/#129 stopped NEW corruption (raised the Excel-serial floor)
-- and HID existing 1905 values at read time — so the Map + Roster no
-- longer SHOW 1905, but the stored value is still 1905 and the cell sits
-- blank until something re-derives it. The client only re-derives on a
-- fresh import or when a clinician's profile history is opened, so the
-- blanks persist.
--
-- This migration FILLS them: it recomputes each clinician's earliest
-- PLAUSIBLE completed-service date (>= 2000-01-01) directly from the
-- TB completed-service import tables and writes it back into
-- tags.derivedStartDate — but ONLY for clinicians whose stored derived
-- value is currently corrupt (pre-2000 / malformed). Explicit hire
-- dates (tags.startDate / start_date) and good derived values are never
-- touched.
--
-- Mirrors the client's getCompletedServiceRowEarliestRelevantDate logic
-- (min across start_of_episode / referral_date / last_visit_date /
-- ended_date) + the new >= 2000 floor. Type-agnostic (casts each column
-- to text, regex-guards a YYYY-MM-DD prefix, then to date) so it works
-- whether the columns are DATE or TEXT and can't error on a malformed
-- value. Idempotent — re-running skips rows already repaired (their
-- derived value is now >= 2000).

BEGIN;

WITH svc_dates AS (
  SELECT
    c.matched_clinician_id AS clinician_id,
    substring(v.dtxt FROM 1 FOR 10)::date AS svc_date
  FROM public.therapy_boss_completed_service_import_clinicians c
  JOIN public.therapy_boss_completed_service_import_rows r
    ON r.id = c.service_row_id
  CROSS JOIN LATERAL (VALUES
    (r.start_of_episode::text),
    (r.referral_date::text),
    (r.last_visit_date::text),
    (r.ended_date::text)
  ) AS v(dtxt)
  WHERE c.matched_clinician_id IS NOT NULL
    AND v.dtxt ~ '^\d{4}-\d{2}-\d{2}'
    AND substring(v.dtxt FROM 1 FOR 10)::date >= DATE '2000-01-01'
),
earliest AS (
  SELECT clinician_id, MIN(svc_date) AS derived
  FROM svc_dates
  GROUP BY clinician_id
)
UPDATE public.clinician_profiles p
SET tags = jsonb_set(
             COALESCE(p.tags, '{}'::jsonb),
             '{derivedStartDate}',
             to_jsonb(e.derived::text),
             true
           ),
    updated_at = now()
FROM earliest e
WHERE p.clinician_id = e.clinician_id
  -- Only repair a CURRENTLY-CORRUPT derived value. Leave good derived
  -- dates and any explicit hire date alone.
  AND p.tags ? 'derivedStartDate'
  AND p.tags->>'derivedStartDate' IS NOT NULL
  AND (
        p.tags->>'derivedStartDate' !~ '^\d{4}-\d{2}-\d{2}'
        OR substring(p.tags->>'derivedStartDate' FROM 1 FOR 10)::date < DATE '2000-01-01'
      );

COMMIT;
