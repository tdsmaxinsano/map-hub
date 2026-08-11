-- Company renewals — recurring filings tracker + yearly reminders + PDFs
-- =====================================================================
-- Prompted by the IL LLC Annual Report (Form LLC-50.1) being filed late
-- (due before 05/01/2026, filed 08/11/2026 → $100 penalty on top of the
-- $75 fee). Gives the portal a place to track every recurring company
-- obligation (annual report, insurance, licenses, …), remind ahead of
-- the due date on the Home 📰 News & Alerts board, and archive the filed
-- PDF per year.
--
--   company_renewals         — one row per recurring obligation
--   company_renewal_filings  — one row per completed filing (history),
--                              with the uploaded document
--   company-documents bucket — PRIVATE (admin-only read + write; files
--                              are fetched via signed URLs)
--   list_company_renewal_alerts() — Home-board reminders (≤60 days out
--                              + overdue); returns rows ONLY to admins
--   record_company_renewal_filing(...) — mark-filed in one call: inserts
--                              the history row and advances next_due_date
--                              by one interval
--
-- Seeded with the IL LLC Annual Report (next due 2027-05-01) and its
-- 2026 filing ($75 fee + $100 penalty, filed 2026-08-11) so the history
-- starts populated — the PDF gets attached from the UI.
--
-- RLS: admin-only across the board (matches Finance posture).
-- Idempotent — safe to re-run. Run after 53_suggest_mirror_map.sql.

BEGIN;

-- ── 1. Tables ────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.company_renewals (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name            TEXT NOT NULL UNIQUE,
  description     TEXT,
  interval_months INTEGER NOT NULL DEFAULT 12 CHECK (interval_months > 0),
  next_due_date   DATE NOT NULL,
  notes           TEXT,
  is_active       BOOLEAN NOT NULL DEFAULT true,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_by      UUID
);

CREATE INDEX IF NOT EXISTS idx_company_renewals_due
  ON public.company_renewals (next_due_date) WHERE is_active;

CREATE TABLE IF NOT EXISTS public.company_renewal_filings (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  renewal_id    UUID NOT NULL REFERENCES public.company_renewals(id) ON DELETE CASCADE,
  filed_on      DATE NOT NULL,
  period_label  TEXT,
  fee_paid      NUMERIC(10,2),
  penalty_paid  NUMERIC(10,2),
  document_path TEXT,
  document_name TEXT,
  notes         TEXT,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  created_by    UUID
);

CREATE INDEX IF NOT EXISTS idx_company_renewal_filings_renewal
  ON public.company_renewal_filings (renewal_id, filed_on DESC);

-- ── 2. RLS — admin-only, both tables ─────────────────────────────────
ALTER TABLE public.company_renewals        ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.company_renewal_filings ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "company_renewals_admin_all" ON public.company_renewals;
CREATE POLICY "company_renewals_admin_all" ON public.company_renewals
  FOR ALL TO authenticated
  USING (EXISTS (SELECT 1 FROM public.user_roles ur
                 WHERE ur.user_id = auth.uid() AND ur.role = 'admin'))
  WITH CHECK (EXISTS (SELECT 1 FROM public.user_roles ur
                      WHERE ur.user_id = auth.uid() AND ur.role = 'admin'));

DROP POLICY IF EXISTS "company_renewal_filings_admin_all" ON public.company_renewal_filings;
CREATE POLICY "company_renewal_filings_admin_all" ON public.company_renewal_filings
  FOR ALL TO authenticated
  USING (EXISTS (SELECT 1 FROM public.user_roles ur
                 WHERE ur.user_id = auth.uid() AND ur.role = 'admin'))
  WITH CHECK (EXISTS (SELECT 1 FROM public.user_roles ur
                      WHERE ur.user_id = auth.uid() AND ur.role = 'admin'));

-- ── 3. Private documents bucket — admin-only read AND write ─────────
-- Mirrors the portal's private-bucket template exactly (39_strata_medb_
-- pdf_storage.sql / 41_staff_pay_reviews.sql): public=false, split
-- admin-read + admin-write policies, files opened via signed URLs.
INSERT INTO storage.buckets (id, name, public)
VALUES ('company-documents', 'company-documents', false)
ON CONFLICT (id) DO NOTHING;

DROP POLICY IF EXISTS "company_documents_admin_read"  ON storage.objects;
DROP POLICY IF EXISTS "company_documents_admin_write" ON storage.objects;

CREATE POLICY "company_documents_admin_read" ON storage.objects
  FOR SELECT TO authenticated
  USING (bucket_id = 'company-documents'
         AND EXISTS (SELECT 1 FROM public.user_roles WHERE user_id = auth.uid() AND role = 'admin'));

CREATE POLICY "company_documents_admin_write" ON storage.objects
  FOR ALL TO authenticated
  USING (bucket_id = 'company-documents'
         AND EXISTS (SELECT 1 FROM public.user_roles WHERE user_id = auth.uid() AND role = 'admin'))
  WITH CHECK (bucket_id = 'company-documents'
              AND EXISTS (SELECT 1 FROM public.user_roles WHERE user_id = auth.uid() AND role = 'admin'));

-- ── 4. Home-board alerts RPC — rows only for admins ──────────────────
DROP FUNCTION IF EXISTS public.list_company_renewal_alerts();

CREATE FUNCTION public.list_company_renewal_alerts()
RETURNS TABLE(
  alert_type   TEXT,
  renewal_id   UUID,
  renewal_name TEXT,
  due_date     DATE,
  days_until   INTEGER
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
    (r.next_due_date - CURRENT_DATE)::int AS days_until
  FROM public.company_renewals r
  WHERE r.is_active
    AND r.next_due_date <= CURRENT_DATE + 60
    -- Company filings are admin business — everyone else gets an empty set.
    AND EXISTS (SELECT 1 FROM public.user_roles ur
                WHERE ur.user_id = auth.uid() AND ur.role = 'admin')
  ORDER BY r.next_due_date;
$$;

REVOKE ALL ON FUNCTION public.list_company_renewal_alerts() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.list_company_renewal_alerts() TO authenticated;

-- ── 5. Mark-filed RPC — history row + advance in one call ────────────
DROP FUNCTION IF EXISTS public.record_company_renewal_filing(UUID, DATE, TEXT, NUMERIC, NUMERIC, TEXT, TEXT, TEXT);

CREATE FUNCTION public.record_company_renewal_filing(
  p_renewal_id    UUID,
  p_filed_on      DATE,
  p_period_label  TEXT    DEFAULT NULL,
  p_fee_paid      NUMERIC DEFAULT NULL,
  p_penalty_paid  NUMERIC DEFAULT NULL,
  p_document_path TEXT    DEFAULT NULL,
  p_document_name TEXT    DEFAULT NULL,
  p_notes         TEXT    DEFAULT NULL
)
RETURNS TABLE(filing_id UUID, new_next_due_date DATE)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_filing_id UUID;
  v_next      DATE;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.user_roles ur
                 WHERE ur.user_id = auth.uid() AND ur.role = 'admin') THEN
    RAISE EXCEPTION 'admin only';
  END IF;

  INSERT INTO public.company_renewal_filings
    (renewal_id, filed_on, period_label, fee_paid, penalty_paid,
     document_path, document_name, notes, created_by)
  VALUES
    (p_renewal_id, p_filed_on, NULLIF(TRIM(COALESCE(p_period_label, '')), ''),
     p_fee_paid, p_penalty_paid,
     NULLIF(TRIM(COALESCE(p_document_path, '')), ''),
     NULLIF(TRIM(COALESCE(p_document_name, '')), ''),
     NULLIF(TRIM(COALESCE(p_notes, '')), ''), auth.uid())
  RETURNING id INTO v_filing_id;

  -- Advance ONE interval from the current due date (the obligation being
  -- satisfied is the upcoming one) — correct for both early and late
  -- filings: due 2026-05-01 filed 2026-08-11 → 2027-05-01;
  -- due 2027-05-01 filed 2027-04-20 → 2028-05-01.
  UPDATE public.company_renewals
     SET next_due_date = (next_due_date + make_interval(months => interval_months))::date,
         updated_at = now(),
         updated_by = auth.uid()
   WHERE id = p_renewal_id
   RETURNING next_due_date INTO v_next;

  IF v_next IS NULL THEN
    RAISE EXCEPTION 'renewal % not found', p_renewal_id;
  END IF;

  RETURN QUERY SELECT v_filing_id, v_next;
END;
$$;

REVOKE ALL ON FUNCTION public.record_company_renewal_filing(UUID, DATE, TEXT, NUMERIC, NUMERIC, TEXT, TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.record_company_renewal_filing(UUID, DATE, TEXT, NUMERIC, NUMERIC, TEXT, TEXT, TEXT) TO authenticated;

-- ── 6. Seed — the IL LLC Annual Report + its (late) 2026 filing ──────
INSERT INTO public.company_renewals (name, description, interval_months, next_due_date, notes)
VALUES (
  'IL LLC Annual Report (Form LLC-50.1)',
  'Illinois Secretary of State annual report for DEPENDABLE CARE STAFFING LLC — file + pay BEFORE May 1 each year at ilsos.gov.',
  12,
  DATE '2027-05-01',
  'File # 06295479 · organized 05/12/2017 · registered agent Madelyn Davila, 9933 Lawler Ave Suite 206 B, Skokie IL 60077 · fee $75, late penalty $100.'
)
ON CONFLICT (name) DO NOTHING;

INSERT INTO public.company_renewal_filings
  (renewal_id, filed_on, period_label, fee_paid, penalty_paid, notes)
SELECT r.id, DATE '2026-08-11', '2026', 75, 100,
       'Filed late (due before 05/01/2026) — $100 penalty paid, $175 total. Attach the stamped LLC-50.1 PDF from the Renewals view.'
FROM public.company_renewals r
WHERE r.name = 'IL LLC Annual Report (Form LLC-50.1)'
  AND NOT EXISTS (
    SELECT 1 FROM public.company_renewal_filings f
    WHERE f.renewal_id = r.id AND f.period_label = '2026'
  );

COMMIT;

NOTIFY pgrst, 'reload schema';
