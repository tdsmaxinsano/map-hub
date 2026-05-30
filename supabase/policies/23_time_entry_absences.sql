-- Day-off / absence tracking on time entries
-- =====================================================================
-- Staff need to log days they MISSED with a reason so admin has context
-- (vacation vs power outage vs internet down vs sick vs personal) instead
-- of just blank/zero hours on the timesheet.
--
-- Schema: one new nullable column on `time_entries`. Allowed values are
-- enforced via CHECK so the dropdown stays the source of truth.
--
--   absence_kind IN ('vacation','power_outage','internet','sick','personal')
--
-- An absence-only day (no worked hours) is stored as a synthetic
-- is_manual time_entry with clock_in = clock_out (zero duration) and
-- absence_kind set. hoursInPeriod naturally adds 0h for these so payroll
-- totals are unaffected — the absence is purely informational.
--
-- Partial-day absences (e.g. 4h sick + half-day) are also supported:
-- a normal time_entry with both hrs > 0 and absence_kind set.
--
-- Idempotent — safe to re-run.

BEGIN;

ALTER TABLE public.time_entries
  ADD COLUMN IF NOT EXISTS absence_kind TEXT;

-- Constraint: drop-then-create so re-running picks up any future value edits.
ALTER TABLE public.time_entries
  DROP CONSTRAINT IF EXISTS time_entries_absence_kind_check;
ALTER TABLE public.time_entries
  ADD CONSTRAINT time_entries_absence_kind_check
  CHECK (absence_kind IS NULL
         OR absence_kind IN ('vacation','power_outage','internet','sick','personal'));

-- Index supports per-period / per-user absence summaries down the road.
CREATE INDEX IF NOT EXISTS idx_time_entries_absence_kind
  ON public.time_entries (absence_kind)
  WHERE absence_kind IS NOT NULL;

COMMIT;

NOTIFY pgrst, 'reload schema';
