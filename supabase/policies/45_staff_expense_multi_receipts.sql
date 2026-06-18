-- Staff expenses — multiple receipts per expense
-- =====================================================================
-- Migration 42 stored a single receipt_url per expense. Staff sometimes
-- have several receipt pages/photos for one purchase, so this adds a
-- receipt_urls JSONB array alongside the existing column.
--
--   * receipt_urls JSONB — the full list of receipt URLs (0..N).
--   * receipt_url stays the "primary" (first) receipt — preserved for
--     backward compatibility AND because the approval flow copies it onto
--     the pay_period_adjustments row (which still carries a single
--     receipt_url). The client reads receipt_urls when present and falls
--     back to [receipt_url] for rows created before this migration.
--
-- One-shot backfill: seed receipt_urls = [receipt_url] for existing rows
-- that have a receipt but an empty array, so old expenses render the same
-- under the new array-aware UI.
--
-- Additive + idempotent.

BEGIN;

ALTER TABLE public.staff_expenses
  ADD COLUMN IF NOT EXISTS receipt_urls JSONB NOT NULL DEFAULT '[]'::jsonb;

-- Relax the amount CHECK from > 0 to >= 0 so the "📎 One per file" bulk flow
-- can create rows at amount 0 (the staff member then fills each in inline).
-- The client + admin approval guard against approving a 0-amount expense.
ALTER TABLE public.staff_expenses
  DROP CONSTRAINT IF EXISTS staff_expenses_amount_check;
ALTER TABLE public.staff_expenses
  ADD CONSTRAINT staff_expenses_amount_check CHECK (amount >= 0);

-- Backfill: existing single receipt → one-element array (only where the
-- array is still empty so re-running is a no-op).
UPDATE public.staff_expenses
   SET receipt_urls = jsonb_build_array(receipt_url)
 WHERE receipt_url IS NOT NULL
   AND (receipt_urls IS NULL OR receipt_urls = '[]'::jsonb);

-- ── Let staff fix + re-submit a DECLINED expense ───────────────────
-- Migration 42 let staff UPDATE/DELETE only their PENDING rows, so a row
-- the admin declined (e.g. "no receipt") was permanently stuck. Widen
-- both to also cover the owner's DECLINED rows. The UPDATE WITH CHECK is
-- tightened so a staff edit must land the row in 'pending' (can't
-- self-approve, and editing a declined row flips it back to the queue).
DROP POLICY IF EXISTS "staff_expenses_update" ON public.staff_expenses;
CREATE POLICY "staff_expenses_update" ON public.staff_expenses
  FOR UPDATE TO authenticated
  USING ((user_id = auth.uid() AND status IN ('pending', 'declined'))
         OR EXISTS (SELECT 1 FROM public.user_roles WHERE user_id = auth.uid() AND role = 'admin'))
  WITH CHECK ((user_id = auth.uid() AND status = 'pending')
              OR EXISTS (SELECT 1 FROM public.user_roles WHERE user_id = auth.uid() AND role = 'admin'));

DROP POLICY IF EXISTS "staff_expenses_delete" ON public.staff_expenses;
CREATE POLICY "staff_expenses_delete" ON public.staff_expenses
  FOR DELETE TO authenticated
  USING ((user_id = auth.uid() AND status IN ('pending', 'declined'))
         OR EXISTS (SELECT 1 FROM public.user_roles WHERE user_id = auth.uid() AND role = 'admin'));

COMMIT;
