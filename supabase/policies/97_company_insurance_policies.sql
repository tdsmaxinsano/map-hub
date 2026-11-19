-- ════════════════════════════════════════════════════════════════════
-- 97 · Company insurance policies (Finance → Renewals → 🛡 Insurance)
--
-- Builds on migration 54 (company_renewals + company_renewal_filings +
-- the PRIVATE company-documents bucket). An insurance policy is a
-- renewal whose next_due_date is the policy EXPIRATION, so the Home
-- 📰 board already reminds 60 days ahead. This adds:
--
--   company_renewals.category  'filing' (default) | 'insurance'
--   insurance columns          coverage_type, carrier, carrier_naic,
--                              policy_number, effective_date, limits,
--                              producer, additional_insureds
--   company_renewal_documents  many documents per renewal/term
--                              (certificate of insurance, declarations
--                              page, policy, invoice, audit, other)
--   list_company_renewal_alerts() now also returns category so the Home
--                              board can say "policy expires" instead of
--                              "filing due" (RETURNS TABLE change →
--                              DROP + CREATE).
--
-- Seeded from the ACORD 25 certificate dated 06/29/2026:
--   • General + Professional Liability — Benchmark Specialty Ins Co,
--     BSICDMRC0107165025AH, 08/20/2025 → 08/20/2026 (claims-made)
--   • Workers' Compensation + Employers' Liability — Diamond Ins Co,
--     DIC2008108, 07/19/2026 → 07/19/2027
-- Attach the certificate PDF from the Renewals view.
--
-- RLS: admin-only (same as migration 54). Idempotent — safe to re-run.
-- ════════════════════════════════════════════════════════════════════
BEGIN;

-- ── 1. Insurance columns on company_renewals ─────────────────────────
ALTER TABLE public.company_renewals
  ADD COLUMN IF NOT EXISTS category            TEXT NOT NULL DEFAULT 'filing',
  ADD COLUMN IF NOT EXISTS coverage_type       TEXT,
  ADD COLUMN IF NOT EXISTS carrier             TEXT,
  ADD COLUMN IF NOT EXISTS carrier_naic        TEXT,
  ADD COLUMN IF NOT EXISTS policy_number       TEXT,
  ADD COLUMN IF NOT EXISTS effective_date      DATE,
  ADD COLUMN IF NOT EXISTS limits              TEXT,
  ADD COLUMN IF NOT EXISTS producer            TEXT,
  ADD COLUMN IF NOT EXISTS additional_insureds TEXT;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'company_renewals_category_chk') THEN
    ALTER TABLE public.company_renewals
      ADD CONSTRAINT company_renewals_category_chk CHECK (category IN ('filing', 'insurance'));
  END IF;
END $$;

-- ── 2. Documents (many per renewal; optionally tied to a term) ───────
CREATE TABLE IF NOT EXISTS public.company_renewal_documents (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  renewal_id    UUID NOT NULL REFERENCES public.company_renewals(id) ON DELETE CASCADE,
  filing_id     UUID REFERENCES public.company_renewal_filings(id) ON DELETE SET NULL,
  doc_type      TEXT NOT NULL DEFAULT 'other',
  document_path TEXT NOT NULL,
  document_name TEXT,
  notes         TEXT,
  uploaded_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
  uploaded_by   UUID
);

CREATE INDEX IF NOT EXISTS idx_company_renewal_documents_renewal
  ON public.company_renewal_documents (renewal_id, uploaded_at DESC);

ALTER TABLE public.company_renewal_documents ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "company_renewal_documents_admin_all" ON public.company_renewal_documents;
CREATE POLICY "company_renewal_documents_admin_all" ON public.company_renewal_documents
  FOR ALL TO authenticated
  USING (EXISTS (SELECT 1 FROM public.user_roles ur
                 WHERE ur.user_id = auth.uid() AND ur.role = 'admin'))
  WITH CHECK (EXISTS (SELECT 1 FROM public.user_roles ur
                      WHERE ur.user_id = auth.uid() AND ur.role = 'admin'));

-- ── 3. Home-board alerts RPC — now with category ─────────────────────
DROP FUNCTION IF EXISTS public.list_company_renewal_alerts();

CREATE FUNCTION public.list_company_renewal_alerts()
RETURNS TABLE(
  alert_type   TEXT,
  renewal_id   UUID,
  renewal_name TEXT,
  due_date     DATE,
  days_until   INTEGER,
  category     TEXT
)
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT
    CASE
      WHEN r.next_due_date <  CURRENT_DATE THEN 'renewal_overdue'
      WHEN r.next_due_date =  CURRENT_DATE THEN 'renewal_due_today'
      ELSE 'renewal_due_soon'
    END AS alert_type,
    r.id,
    r.name,
    r.next_due_date,
    (r.next_due_date - CURRENT_DATE)::int AS days_until,
    r.category
  FROM public.company_renewals r
  WHERE r.is_active
    AND r.next_due_date <= CURRENT_DATE + 60
    AND EXISTS (SELECT 1 FROM public.user_roles ur
                WHERE ur.user_id = auth.uid() AND ur.role = 'admin')
  ORDER BY r.next_due_date;
$$;

REVOKE ALL ON FUNCTION public.list_company_renewal_alerts() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.list_company_renewal_alerts() TO authenticated;

-- ── 4. Seed the two policies from the 06/29/2026 certificate ─────────
INSERT INTO public.company_renewals
  (name, description, interval_months, next_due_date, notes, category, coverage_type,
   carrier, carrier_naic, policy_number, effective_date, limits, producer, additional_insureds)
VALUES (
  'General & Professional Liability',
  'Commercial general liability + professional liability (claims-made).',
  12, DATE '2026-08-20',
  'Per ACORD 25 certificate dated 06/29/2026. Confirm the 08/20/2026 renewal and upload the new certificate.',
  'insurance', 'general_liability',
  'Benchmark Specialty Ins Co', '17180', 'BSICDMRC0107165025AH', DATE '2025-08-20',
  'Each occurrence $1,000,000 · General aggregate $3,000,000 · Personal & adv injury $1,000,000 · Damage to rented premises $50,000 · Med exp $5,000 · Products-comp/op agg included · Deductible $2,500',
  'Bliss Marc International Corp, 7905 Lyons St, Morton Grove IL 60053 — Tracy Ramos · (847) 962-9050 · fax (847) 470-0844 · kramos@blissmarc.com',
  'Northeast Bank'
)
ON CONFLICT (name) DO NOTHING;

INSERT INTO public.company_renewals
  (name, description, interval_months, next_due_date, notes, category, coverage_type,
   carrier, carrier_naic, policy_number, effective_date, limits, producer, additional_insureds)
VALUES (
  'Workers'' Compensation & Employers'' Liability',
  'Workers'' compensation (statutory) + employers'' liability. Proprietor/partner/executive officer excluded: Y.',
  12, DATE '2027-07-19',
  'Per ACORD 25 certificate dated 06/29/2026.',
  'insurance', 'workers_comp',
  'Diamond Ins Co', '10659', 'DIC2008108', DATE '2026-07-19',
  'E.L. each accident $100,000 · E.L. disease each employee $100,000 · E.L. disease policy limit $500,000',
  'Bliss Marc International Corp, 7905 Lyons St, Morton Grove IL 60053 — Tracy Ramos · (847) 962-9050 · fax (847) 470-0844 · kramos@blissmarc.com',
  NULL
)
ON CONFLICT (name) DO NOTHING;

NOTIFY pgrst, 'reload schema';

COMMIT;
