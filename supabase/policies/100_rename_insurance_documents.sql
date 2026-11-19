-- ════════════════════════════════════════════════════════════════════
-- 100 · One-time: rename existing insurance documents to the new
--       "<Policy> <Type> <YYYY-YYYY>.<ext>" pattern
--
-- New uploads are auto-named by finance.html (e.g. "COI 2026-2027.pdf",
-- "Workers Comp Policy 2026-2027.pdf"). This brings documents uploaded
-- before that change in line, using each policy's CURRENT term.
-- Only document_name changes (what the page shows + the email
-- attachment's filename); the stored file path is untouched.
-- Safe to re-run.
-- ════════════════════════════════════════════════════════════════════
BEGIN;

UPDATE public.company_renewal_documents d
SET document_name =
  concat_ws(' ',
    CASE WHEN d.doc_type = 'coi' THEN NULL ELSE
      CASE r.coverage_type
        WHEN 'general_liability'      THEN 'General & Professional Liability'
        WHEN 'professional_liability' THEN 'Professional Liability'
        WHEN 'workers_comp'           THEN 'Workers Comp'
        WHEN 'auto'                   THEN 'Commercial Auto'
        WHEN 'umbrella'               THEN 'Umbrella'
        WHEN 'cyber'                  THEN 'Cyber'
        ELSE r.name
      END
    END,
    CASE d.doc_type
      WHEN 'coi'         THEN 'COI'
      WHEN 'dec'         THEN 'Dec Page'
      WHEN 'policy'      THEN 'Policy'
      WHEN 'invoice'     THEN 'Invoice'
      WHEN 'audit'       THEN 'Audit'
      WHEN 'endorsement' THEN 'Endorsement'
      ELSE 'Document'
    END,
    coalesce(extract(year FROM r.effective_date)::int, extract(year FROM r.next_due_date)::int - 1)::text
      || '-' || extract(year FROM r.next_due_date)::int::text
  ) || lower(coalesce(substring(d.document_name FROM '\.[A-Za-z0-9]{2,5}$'), '.pdf'))
FROM public.company_renewals r
WHERE r.id = d.renewal_id
  AND r.category = 'insurance';

COMMIT;
