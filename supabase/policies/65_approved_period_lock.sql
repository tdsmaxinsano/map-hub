-- Approved pay periods are LOCKED for the employee (migration 22 follow-up)
-- =========================================================================
-- Migration 22's design said "approval is a stamp, not a hard lock" — the
-- staff badge even reads "✓ Approved — final", but nothing enforced it:
--   * the staff timesheet grid stayed fully editable after approval, and
--   * submit_pay_period allowed a re-submit from ANY state, which flipped
--     an approved period back to 'submitted' and NULLed the approval
--     stamps — an employee could change hours after approval and the
--     admin's approval silently vanished.
--
-- This migration makes approval a real lock on the EMPLOYEE side:
--   1. submit_pay_period now REFUSES when the period is already approved
--      ("ask an admin to send it back first"). The admin's ↩ Send Back
--      (reject_pay_period) remains the official unlock.
--   2. A trigger on time_entries blocks a non-admin user's writes to
--      their OWN manual/timesheet rows when the entry's day falls inside
--      one of their approved periods — so the lock holds at the API
--      level, not just in the UI. Live clock in/out rows
--      (is_manual = false) are never blocked, and ADMINS always pass:
--      the admin timesheet editor + Shifts modal deliberately keep
--      working on approved periods (the admin is the authority, and
--      their edits carry the [adm …] redline stamp).
--
-- Client pairing (same PR): the staff grid renders read-only with a
-- "locked" badge when the period is approved.
--
-- Idempotent — safe to re-run. Run after 64_user_invites_and_roles.sql.

BEGIN;

-- ── 1. submit_pay_period: refuse on an approved period ───────────────
CREATE OR REPLACE FUNCTION public.submit_pay_period(p_period_start DATE)
RETURNS public.pay_period_submissions
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE r public.pay_period_submissions;
BEGIN
  -- Approved = locked. The admin must Send Back (reject) to reopen.
  IF EXISTS (
    SELECT 1 FROM pay_period_submissions
    WHERE user_id = auth.uid() AND period_start = p_period_start
      AND status = 'approved'
  ) THEN
    RAISE EXCEPTION 'This pay period is approved and locked — ask an admin to send it back before editing.';
  END IF;

  INSERT INTO pay_period_submissions
    (user_id, period_start, status, submitted_at, submitted_by, admin_notes, updated_at)
  VALUES
    (auth.uid(), p_period_start, 'submitted', now(), auth.uid(), NULL, now())
  ON CONFLICT (user_id, period_start) DO UPDATE
    SET status       = 'submitted',
        submitted_at = now(),
        submitted_by = auth.uid(),
        admin_notes  = NULL,            -- clear stale "send back" note on re-submit
        approved_at  = NULL,
        approved_by  = NULL,
        updated_at   = now()
  RETURNING * INTO r;
  RETURN r;
END $$;

REVOKE ALL ON FUNCTION public.submit_pay_period(DATE) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.submit_pay_period(DATE) TO authenticated;

-- ── 2. time_entries trigger: employee writes blocked in approved periods ──
CREATE OR REPLACE FUNCTION public.enforce_approved_period_lock()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  rec       public.time_entries;
  entry_day DATE;
  old_day   DATE;
BEGIN
  rec := COALESCE(NEW, OLD);

  -- Live clock in/out rows are never blocked (only manual/timesheet rows).
  IF COALESCE(rec.is_manual, false) = false THEN
    RETURN COALESCE(NEW, OLD);
  END IF;
  -- Only the employee editing THEIR OWN rows is guarded; service-role
  -- jobs and admins editing someone else pass through here.
  IF auth.uid() IS NULL OR auth.uid() IS DISTINCT FROM rec.user_id THEN
    RETURN COALESCE(NEW, OLD);
  END IF;
  -- Admins are the authority — their edits stay allowed after approval.
  IF EXISTS (SELECT 1 FROM public.user_roles ur
             WHERE ur.user_id = auth.uid() AND ur.role = 'admin') THEN
    RETURN COALESCE(NEW, OLD);
  END IF;

  -- Bi-weekly periods are 14 days starting at period_start (UTC-date
  -- convention matches the client's period.start.toISOString().slice(0,10)).
  entry_day := (rec.clock_in AT TIME ZONE 'UTC')::date;
  IF EXISTS (
    SELECT 1 FROM public.pay_period_submissions s
    WHERE s.user_id = rec.user_id
      AND s.status = 'approved'
      AND s.period_start <= entry_day
      AND entry_day < s.period_start + 14
  ) THEN
    RAISE EXCEPTION 'This pay period is approved and locked — ask an admin to send it back before editing.';
  END IF;

  -- An UPDATE must not move a row OUT of a locked period either.
  IF TG_OP = 'UPDATE' THEN
    old_day := (OLD.clock_in AT TIME ZONE 'UTC')::date;
    IF old_day IS DISTINCT FROM entry_day AND EXISTS (
      SELECT 1 FROM public.pay_period_submissions s
      WHERE s.user_id = OLD.user_id
        AND s.status = 'approved'
        AND s.period_start <= old_day
        AND old_day < s.period_start + 14
    ) THEN
      RAISE EXCEPTION 'This pay period is approved and locked — ask an admin to send it back before editing.';
    END IF;
  END IF;

  RETURN COALESCE(NEW, OLD);
END $$;

DROP TRIGGER IF EXISTS trg_approved_period_lock ON public.time_entries;
CREATE TRIGGER trg_approved_period_lock
  BEFORE INSERT OR UPDATE OR DELETE ON public.time_entries
  FOR EACH ROW EXECUTE FUNCTION public.enforce_approved_period_lock();

COMMIT;

NOTIFY pgrst, 'reload schema';
