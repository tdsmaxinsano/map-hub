-- Pay-period submission + admin approval workflow
-- =====================================================================
-- Today payroll has no explicit "the employee says this is done" or
-- "the admin signed off" marker — the only signal is the email of the
-- Excel timesheet. This adds a per-(employee, period) submission row
-- with a 4-state machine and lightweight RPCs so the UI can show
-- status badges + approve buttons in:
--   * the staff My Timesheet card (their own status)
--   * the admin Dashboard cards (one per employee)
--   * the admin Pay Period rows + Shifts modal (review + approve)
--
-- States:
--   draft     — no submission record OR explicit pre-submit state
--   submitted — employee clicked "Submit Timesheet"; awaiting admin review
--   approved  — admin stamped it; pay can be finalized
--   rejected  — admin sent it back with a note; employee re-submits to flip
--               back to submitted
--
-- Approval is a stamp, not a hard lock: admin can still edit hours /
-- adjustments after approval (matches today's behavior). We can add
-- hard-locking later if needed.
--
-- Idempotent — safe to re-run.

BEGIN;

CREATE TABLE IF NOT EXISTS public.pay_period_submissions (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id       UUID NOT NULL,
  period_start  DATE NOT NULL,                                   -- matches the time_tracker pay-period anchor
  status        TEXT NOT NULL DEFAULT 'draft',                   -- draft | submitted | approved | rejected
  submitted_at  TIMESTAMPTZ,
  submitted_by  UUID,
  approved_at   TIMESTAMPTZ,
  approved_by   UUID,
  admin_notes   TEXT,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (user_id, period_start)
);

CREATE INDEX IF NOT EXISTS idx_pps_user_period ON public.pay_period_submissions (user_id, period_start DESC);
CREATE INDEX IF NOT EXISTS idx_pps_status      ON public.pay_period_submissions (status) WHERE status <> 'approved';

ALTER TABLE public.pay_period_submissions ENABLE ROW LEVEL SECURITY;

-- Read: any authenticated user can read their own row + admin reads all.
DROP POLICY IF EXISTS "pps_select_own_or_admin" ON public.pay_period_submissions;
CREATE POLICY "pps_select_own_or_admin" ON public.pay_period_submissions
  FOR SELECT TO authenticated
  USING (
    user_id = auth.uid()
    OR EXISTS (SELECT 1 FROM public.user_roles WHERE user_id = auth.uid() AND role = 'admin')
  );

-- Write: routed through SECURITY DEFINER RPCs (no direct INSERT/UPDATE).
-- RLS leaves the table closed to direct writes for non-admins.
DROP POLICY IF EXISTS "pps_admin_write" ON public.pay_period_submissions;
CREATE POLICY "pps_admin_write" ON public.pay_period_submissions
  FOR ALL TO authenticated
  USING      (EXISTS (SELECT 1 FROM public.user_roles WHERE user_id = auth.uid() AND role = 'admin'))
  WITH CHECK (EXISTS (SELECT 1 FROM public.user_roles WHERE user_id = auth.uid() AND role = 'admin'));

-- ── RPC: staff submits their own period ───────────────────────────────
-- Idempotent — re-submitting just refreshes submitted_at + clears any
-- prior admin notes. If previously rejected, this flips it back to
-- submitted (the employee fixed something and is asking again).
CREATE OR REPLACE FUNCTION public.submit_pay_period(p_period_start DATE)
RETURNS public.pay_period_submissions
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE r public.pay_period_submissions;
BEGIN
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

-- ── RPC: list submissions for a period (admin: all; staff: own only) ──
CREATE OR REPLACE FUNCTION public.list_pay_period_submissions(p_period_start DATE)
RETURNS SETOF public.pay_period_submissions
LANGUAGE sql SECURITY DEFINER SET search_path = public AS $$
  SELECT * FROM pay_period_submissions
   WHERE period_start = p_period_start
     AND (
       user_id = auth.uid()
       OR EXISTS (SELECT 1 FROM user_roles WHERE user_id = auth.uid() AND role = 'admin')
     );
$$;

-- ── RPC: admin approves a submission ──────────────────────────────────
CREATE OR REPLACE FUNCTION public.approve_pay_period(
  p_user_id UUID, p_period_start DATE
) RETURNS public.pay_period_submissions
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE r public.pay_period_submissions;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM user_roles WHERE user_id = auth.uid() AND role = 'admin') THEN
    RAISE EXCEPTION 'Only admin may approve';
  END IF;
  -- Upsert so the admin can approve even if the staff never explicitly
  -- submitted (e.g. clocked-in hours only).
  INSERT INTO pay_period_submissions
    (user_id, period_start, status, approved_at, approved_by, updated_at)
  VALUES
    (p_user_id, p_period_start, 'approved', now(), auth.uid(), now())
  ON CONFLICT (user_id, period_start) DO UPDATE
    SET status      = 'approved',
        approved_at = now(),
        approved_by = auth.uid(),
        updated_at  = now()
  RETURNING * INTO r;
  RETURN r;
END $$;

-- ── RPC: admin sends a submission back with a note ────────────────────
CREATE OR REPLACE FUNCTION public.reject_pay_period(
  p_user_id UUID, p_period_start DATE, p_note TEXT
) RETURNS public.pay_period_submissions
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE r public.pay_period_submissions;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM user_roles WHERE user_id = auth.uid() AND role = 'admin') THEN
    RAISE EXCEPTION 'Only admin may reject';
  END IF;
  INSERT INTO pay_period_submissions
    (user_id, period_start, status, admin_notes, approved_at, approved_by, updated_at)
  VALUES
    (p_user_id, p_period_start, 'rejected', p_note, NULL, NULL, now())
  ON CONFLICT (user_id, period_start) DO UPDATE
    SET status      = 'rejected',
        admin_notes = p_note,
        approved_at = NULL,
        approved_by = NULL,
        updated_at  = now()
  RETURNING * INTO r;
  RETURN r;
END $$;

REVOKE ALL ON FUNCTION public.submit_pay_period(DATE)                       FROM PUBLIC;
REVOKE ALL ON FUNCTION public.list_pay_period_submissions(DATE)             FROM PUBLIC;
REVOKE ALL ON FUNCTION public.approve_pay_period(UUID, DATE)                FROM PUBLIC;
REVOKE ALL ON FUNCTION public.reject_pay_period(UUID, DATE, TEXT)           FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.submit_pay_period(DATE)                    TO authenticated;
GRANT EXECUTE ON FUNCTION public.list_pay_period_submissions(DATE)          TO authenticated;
GRANT EXECUTE ON FUNCTION public.approve_pay_period(UUID, DATE)             TO authenticated;
GRANT EXECUTE ON FUNCTION public.reject_pay_period(UUID, DATE, TEXT)        TO authenticated;

COMMIT;

NOTIFY pgrst, 'reload schema';
