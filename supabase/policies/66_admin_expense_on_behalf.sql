-- Admin can add a staff expense ON BEHALF of an employee (migration 42 follow-up)
-- ==============================================================================
-- Migration 42's INSERT policy on staff_expenses was own-rows-only
-- (WITH CHECK user_id = auth.uid()), so an admin could approve/decline/edit
-- anything but could NOT create an expense for someone else — e.g. logging a
-- receipt an employee handed over in person. The 🗓 Staff Timesheet modal now
-- has an "＋ Add expense for <name>" form; this widens the INSERT policy so
-- that form works. The row is created as 'pending' (status default) and flows
-- through the normal 💸 Expense Approvals queue — adding ≠ approving.
--
-- Receipts: no storage change needed — the reimbursement-receipts bucket has
-- had an admin FOR ALL write policy since migration 21, so admin uploads to
-- staff-expenses/<employee uid>/… already pass.
--
-- Idempotent — safe to re-run. Run after 65_approved_period_lock.sql.

BEGIN;

DROP POLICY IF EXISTS "staff_expenses_insert_own" ON public.staff_expenses;
CREATE POLICY "staff_expenses_insert_own" ON public.staff_expenses
  FOR INSERT TO authenticated
  WITH CHECK (
    user_id = auth.uid()
    OR EXISTS (SELECT 1 FROM public.user_roles WHERE user_id = auth.uid() AND role = 'admin')
  );

COMMIT;

NOTIFY pgrst, 'reload schema';
