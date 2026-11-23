-- ════════════════════════════════════════════════════════════════════
-- 101 · One-time cleanup: fold the separate "General liability" card
--       (the expired 2025–2026 term) into "General & Professional
--       Liability" as its previous term, and drop duplicate documents.
--
-- 1. Move that card's documents + any history onto the real policy.
--    Their names ("COI 2025-2026.pdf") put them under
--    "Previous-term documents" on the page.
-- 2. Log the 2025–2026 term in the policy's Past terms.
-- 3. Delete the extra card (now empty).
-- 4. Correct the current term's start date to 08/20/2026.
-- 5. Remove the mistaken "2027–2028" past-term lines, if still there.
-- 6. Remove duplicate document rows (same policy + type + name),
--    keeping the earliest upload.
-- Safe to re-run.
-- ════════════════════════════════════════════════════════════════════
BEGIN;

-- 1.
UPDATE public.company_renewal_documents d
SET renewal_id = g.id
FROM public.company_renewals old, public.company_renewals g
WHERE d.renewal_id = old.id
  AND old.name = 'General liability' AND old.category = 'insurance'
  AND g.name = 'General & Professional Liability';

UPDATE public.company_renewal_filings f
SET renewal_id = g.id
FROM public.company_renewals old, public.company_renewals g
WHERE f.renewal_id = old.id
  AND old.name = 'General liability' AND old.category = 'insurance'
  AND g.name = 'General & Professional Liability';

-- 2.
INSERT INTO public.company_renewal_filings (renewal_id, filed_on, period_label, notes)
SELECT g.id, DATE '2025-08-20', '2025–2026',
       'Prior term 08/20/2025 – 08/20/2026 · policy BSICDMRC0107165025AH'
FROM public.company_renewals g
WHERE g.name = 'General & Professional Liability'
  AND NOT EXISTS (SELECT 1 FROM public.company_renewal_filings f
                  WHERE f.renewal_id = g.id AND f.period_label = '2025–2026');

-- 3.
DELETE FROM public.company_renewals
WHERE name = 'General liability' AND category = 'insurance';

-- 4.
UPDATE public.company_renewals
SET effective_date = DATE '2026-08-20', updated_at = now()
WHERE name = 'General & Professional Liability';

-- 5.
DELETE FROM public.company_renewal_filings f
USING public.company_renewals r
WHERE r.id = f.renewal_id AND r.category = 'insurance' AND f.period_label = '2027–2028';

-- 6.
DELETE FROM public.company_renewal_documents d
USING public.company_renewal_documents k
WHERE d.renewal_id = k.renewal_id
  AND d.doc_type = k.doc_type
  AND d.document_name = k.document_name
  AND (d.uploaded_at, d.id) > (k.uploaded_at, k.id);

COMMIT;
