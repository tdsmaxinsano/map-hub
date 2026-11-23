-- ════════════════════════════════════════════════════════════════════
-- 102 · Zelis payments (Finance → QB Tools → 🏦 Bank Match)
--
-- Insurance payments that reach Chase through Zelis post as
-- "ORIG CO NAME:PayPlus" / "PAY PLUS" instead of the insurer. Dropping
-- the Zelis "Batch EOP" CSV into Bank Match stores ONE ROW PER PAYMENT
-- here so those deposits can be labelled with the real payer (Anthem /
-- BCBS) and the Zelis payment ID — across sessions.
--
-- PAYMENT-LEVEL ONLY. The Zelis CSV is claim-line detail with patient
-- names, DOB and member IDs (PHI); the page aggregates it in the
-- browser and never sends or stores any patient/claim column.
--
-- deposit_date / deposit_trace are filled when a Chase deposit is
-- matched, so "Zelis payments not yet deposited" stays visible.
--
-- RLS: admin-only (same as patient_check_deposits, migration 31).
-- Idempotent.
-- ════════════════════════════════════════════════════════════════════
BEGIN;

CREATE TABLE IF NOT EXISTS public.zelis_payments (
  payment_id    TEXT PRIMARY KEY,
  payer_name    TEXT,
  paid_date     DATE,
  amount        NUMERIC(12,2) NOT NULL,
  claim_count   INTEGER,
  imported_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
  imported_by   UUID,
  deposit_date  DATE,
  deposit_trace TEXT
);

CREATE INDEX IF NOT EXISTS idx_zelis_payments_paid_date
  ON public.zelis_payments (paid_date DESC);

ALTER TABLE public.zelis_payments ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "zelis_payments_admin_all" ON public.zelis_payments;
CREATE POLICY "zelis_payments_admin_all" ON public.zelis_payments
  FOR ALL TO authenticated
  USING (EXISTS (SELECT 1 FROM public.user_roles ur
                 WHERE ur.user_id = auth.uid() AND ur.role = 'admin'))
  WITH CHECK (EXISTS (SELECT 1 FROM public.user_roles ur
                      WHERE ur.user_id = auth.uid() AND ur.role = 'admin'));

NOTIFY pgrst, 'reload schema';

COMMIT;
