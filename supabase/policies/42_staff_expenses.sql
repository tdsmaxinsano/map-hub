-- Staff expenses — self-entry (PHP/USD) + admin approve → reimbursement
-- =====================================================================
-- Employees sometimes buy things for the office (coffee runs, party
-- favors) in PHP or USD. This gives them a place to record it:
--
--   staff (Time Tracker → 💸 My Expenses card): submit date /
--   description / amount / currency / optional receipt photo →
--   status 'pending'. Can edit/withdraw while pending.
--
--   admin (Pay Period → 💸 Expense Approvals card): ✓ Approve converts
--   the expense into a kind='reimbursement' pay_period_adjustments row
--   on the pay period being viewed (the existing reimbursement flow —
--   Wise/US pay math, sendable sub-rows, receipt links all already
--   work downstream). USD conversion happens at approval time using
--   the #php-rate input, captured in fx_rate. ✕ Decline records a
--   reason the staff member can see.
--
-- Additive + idempotent.

BEGIN;

-- ── 1. Table ───────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.staff_expenses (
  id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id        UUID NOT NULL,                 -- the staff member who spent
  expense_date   DATE NOT NULL DEFAULT CURRENT_DATE,
  description    TEXT NOT NULL,                 -- "Office coffee", "Party favors"
  amount         NUMERIC(10,2) NOT NULL CHECK (amount > 0),   -- as entered
  currency       TEXT NOT NULL DEFAULT 'PHP' CHECK (currency IN ('PHP', 'USD')),
  receipt_url    TEXT,
  status         TEXT NOT NULL DEFAULT 'pending'
                   CHECK (status IN ('pending', 'approved', 'declined')),
  reviewed_at    TIMESTAMPTZ,
  reviewed_by    UUID,
  decline_reason TEXT,
  adjustment_id  UUID,                          -- pay_period_adjustments.id on approval
  created_at     TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_staff_expenses_user
  ON public.staff_expenses (user_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_staff_expenses_pending
  ON public.staff_expenses (created_at) WHERE status = 'pending';

-- ── 2. RLS ─────────────────────────────────────────────────────────
ALTER TABLE public.staff_expenses ENABLE ROW LEVEL SECURITY;

-- Read: own rows, or admin reads all.
DROP POLICY IF EXISTS "staff_expenses_select" ON public.staff_expenses;
CREATE POLICY "staff_expenses_select" ON public.staff_expenses
  FOR SELECT TO authenticated
  USING (user_id = auth.uid()
         OR EXISTS (SELECT 1 FROM public.user_roles WHERE user_id = auth.uid() AND role = 'admin'));

-- Insert: own rows only (created as pending by default).
DROP POLICY IF EXISTS "staff_expenses_insert_own" ON public.staff_expenses;
CREATE POLICY "staff_expenses_insert_own" ON public.staff_expenses
  FOR INSERT TO authenticated
  WITH CHECK (user_id = auth.uid());

-- Update: staff may edit their own rows while still pending (withdraw is
-- DELETE below); admin may update anything (the approve/decline path).
DROP POLICY IF EXISTS "staff_expenses_update" ON public.staff_expenses;
CREATE POLICY "staff_expenses_update" ON public.staff_expenses
  FOR UPDATE TO authenticated
  USING ((user_id = auth.uid() AND status = 'pending')
         OR EXISTS (SELECT 1 FROM public.user_roles WHERE user_id = auth.uid() AND role = 'admin'))
  WITH CHECK (user_id = auth.uid()
              OR EXISTS (SELECT 1 FROM public.user_roles WHERE user_id = auth.uid() AND role = 'admin'));

-- Delete: staff may withdraw their own pending rows; admin may delete any.
DROP POLICY IF EXISTS "staff_expenses_delete" ON public.staff_expenses;
CREATE POLICY "staff_expenses_delete" ON public.staff_expenses
  FOR DELETE TO authenticated
  USING ((user_id = auth.uid() AND status = 'pending')
         OR EXISTS (SELECT 1 FROM public.user_roles WHERE user_id = auth.uid() AND role = 'admin'));

-- ── 3. Scoped staff write on the receipts bucket ───────────────────
-- The reimbursement-receipts bucket (migration 21) is public-read +
-- admin-write. Staff need to upload their OWN expense receipts, so add
-- a write policy scoped to the per-user prefix
-- staff-expenses/<auth.uid()>/… — staff can't touch admin receipt
-- paths or each other's folders.
DROP POLICY IF EXISTS "reimbursement_receipts_staff_expense_write" ON storage.objects;
CREATE POLICY "reimbursement_receipts_staff_expense_write" ON storage.objects
  FOR INSERT TO authenticated
  WITH CHECK (
    bucket_id = 'reimbursement-receipts'
    AND name LIKE 'staff-expenses/' || auth.uid()::text || '/%'
  );

COMMIT;

NOTIFY pgrst, 'reload schema';
