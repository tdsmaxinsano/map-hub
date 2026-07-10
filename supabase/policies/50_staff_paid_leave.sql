-- Paid Leave — per-employee benefit + a payable, tracked time-off type.
-- =====================================================================
-- One employee has a paid-leave benefit (PTO). Unlike the existing UNPAID
-- Time Off types (vacation / sick / personal / power_outage / internet, which
-- are logged as zero-duration rows so they don't affect pay), paid leave is
-- logged WITH hours — so those hours are paid (the payroll math already sums
-- entered hours regardless of absence_kind) — and it's a distinct category HR
-- can track. It's gated per-employee so only staff who actually have the
-- benefit see the option on My Timesheet.
--
-- Two additive, idempotent changes:
--   1. staff_config.has_paid_leave — eligibility flag (default false).
--   2. Extend the time_entries.absence_kind CHECK to allow 'paid_leave'.
--
-- No backfill (default false; the new value isn't in use yet).
-- Idempotent — safe to re-run. Run after: 23_time_entry_absences.sql.

BEGIN;

-- ── 1. Per-employee eligibility flag ──────────────────────────────
ALTER TABLE public.staff_config
  ADD COLUMN IF NOT EXISTS has_paid_leave BOOLEAN NOT NULL DEFAULT false;

COMMENT ON COLUMN public.staff_config.has_paid_leave IS
  'True → this employee has a paid-leave benefit; the 🌴 Paid Leave time-off type shows on their My Timesheet. Admin-set in Settings.';

-- ── 2. Allow the paid_leave absence value ─────────────────────────
-- Rebuild the CHECK from 23_time_entry_absences.sql (drop-then-add so a
-- re-run picks up the widened value list) to also permit 'paid_leave'.
ALTER TABLE public.time_entries
  DROP CONSTRAINT IF EXISTS time_entries_absence_kind_check;
ALTER TABLE public.time_entries
  ADD CONSTRAINT time_entries_absence_kind_check
  CHECK (absence_kind IS NULL
         OR absence_kind IN ('vacation','power_outage','internet','sick','personal','paid_leave'));

COMMIT;

NOTIFY pgrst, 'reload schema';
