-- ════════════════════════════════════════════════════════════════════
-- 98 · Insurance certificate send log (Finance → Renewals → 🛡 Insurance)
--
-- Every time the certificate of insurance goes to a vendor / agency —
-- emailed from the portal (send-insurance-certificate edge function) or
-- sent by hand and logged — one row lands here, so "when did we last
-- send ABC Home Health our COI?" has an answer.
--
--   method 'email'  → sent by the edge function (service role inserts)
--          'manual' → sent outside the portal, logged from the page
--
-- RLS: admin-only (same as migrations 54 / 97). Idempotent.
-- ════════════════════════════════════════════════════════════════════
BEGIN;

CREATE TABLE IF NOT EXISTS public.company_insurance_sends (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  document_id   UUID REFERENCES public.company_renewal_documents(id) ON DELETE SET NULL,
  document_name TEXT,
  vendor_name   TEXT NOT NULL,
  recipients    TEXT[] NOT NULL DEFAULT '{}',
  message       TEXT,
  method        TEXT NOT NULL DEFAULT 'email',
  sent_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
  sent_by       UUID,
  sent_by_email TEXT
);

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'company_insurance_sends_method_chk') THEN
    ALTER TABLE public.company_insurance_sends
      ADD CONSTRAINT company_insurance_sends_method_chk CHECK (method IN ('email', 'manual'));
  END IF;
END $$;

CREATE INDEX IF NOT EXISTS idx_company_insurance_sends_sent_at
  ON public.company_insurance_sends (sent_at DESC);

ALTER TABLE public.company_insurance_sends ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "company_insurance_sends_admin_all" ON public.company_insurance_sends;
CREATE POLICY "company_insurance_sends_admin_all" ON public.company_insurance_sends
  FOR ALL TO authenticated
  USING (EXISTS (SELECT 1 FROM public.user_roles ur
                 WHERE ur.user_id = auth.uid() AND ur.role = 'admin'))
  WITH CHECK (EXISTS (SELECT 1 FROM public.user_roles ur
                      WHERE ur.user_id = auth.uid() AND ur.role = 'admin'));

NOTIFY pgrst, 'reload schema';

COMMIT;
