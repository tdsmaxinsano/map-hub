-- ════════════════════════════════════════════════════════════════════
-- 74 · Staff expenses — 'paid' status after 'approved'
--
-- Approved only means the reimbursement row was created; it says
-- nothing about the money actually going out. Admins can now stamp an
-- approved expense as PAID (💰 pill on both the employee's My Expenses
-- card and the admin's per-staff view), with an audit stamp.
--
-- Lifecycle: pending → approved → paid (declined unchanged).
-- Staff RLS (migration 42/45) only lets owners touch their own
-- pending/declined rows, so only admins can mark paid or undo it.
-- Idempotent.
-- ════════════════════════════════════════════════════════════════════
BEGIN;

ALTER TABLE public.staff_expenses
  DROP CONSTRAINT IF EXISTS staff_expenses_status_check;
ALTER TABLE public.staff_expenses
  ADD CONSTRAINT staff_expenses_status_check
  CHECK (status IN ('pending', 'approved', 'declined', 'paid'));

ALTER TABLE public.staff_expenses ADD COLUMN IF NOT EXISTS paid_at TIMESTAMPTZ;
ALTER TABLE public.staff_expenses ADD COLUMN IF NOT EXISTS paid_by UUID;

NOTIFY pgrst, 'reload schema';

COMMIT;
