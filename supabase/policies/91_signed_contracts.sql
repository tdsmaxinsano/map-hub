-- ════════════════════════════════════════════════════════════════════
-- 91 · Signed contract archive (contracts.html 📁 card)
--
-- After an agency signs the Professional Services Agreement, the
-- office scans it and uploads it here: one row per signed contract,
-- the file in the PRIVATE signed-contracts bucket. agency_id links to
-- home_health_agencies when the agency already exists in the portal;
-- contracts signed BEFORE the agency is imported store just the typed
-- name (agency_id NULL) and the 🔁 Re-link pass matches them by name
-- after the next agency import. Admin-only RLS. Idempotent.
-- ════════════════════════════════════════════════════════════════════
BEGIN;

CREATE TABLE IF NOT EXISTS public.agency_contract_files (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  agency_id       TEXT REFERENCES public.home_health_agencies(id),
  agency_name     TEXT NOT NULL,          -- as typed / on the contract
  effective_date  DATE,
  file_path       TEXT,                   -- signed-contracts bucket object
  notes           TEXT,
  uploaded_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
  created_by      UUID
);

CREATE INDEX IF NOT EXISTS agency_contract_files_agency_idx
  ON public.agency_contract_files (agency_id);

ALTER TABLE public.agency_contract_files ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "contractfile_admin_read" ON public.agency_contract_files;
CREATE POLICY "contractfile_admin_read" ON public.agency_contract_files
  FOR SELECT TO authenticated
  USING (EXISTS (SELECT 1 FROM public.user_roles
                 WHERE user_id = auth.uid() AND role = 'admin'));

DROP POLICY IF EXISTS "contractfile_admin_write" ON public.agency_contract_files;
CREATE POLICY "contractfile_admin_write" ON public.agency_contract_files
  FOR ALL TO authenticated
  USING (EXISTS (SELECT 1 FROM public.user_roles
                 WHERE user_id = auth.uid() AND role = 'admin'))
  WITH CHECK (EXISTS (SELECT 1 FROM public.user_roles
                      WHERE user_id = auth.uid() AND role = 'admin'));

-- ── Private bucket for the scanned/signed PDFs ───────────────────────
INSERT INTO storage.buckets (id, name, public)
VALUES ('signed-contracts', 'signed-contracts', false)
ON CONFLICT (id) DO NOTHING;

DROP POLICY IF EXISTS "signedcontract_admin_all" ON storage.objects;
CREATE POLICY "signedcontract_admin_all" ON storage.objects
  FOR ALL TO authenticated
  USING (bucket_id = 'signed-contracts'
         AND EXISTS (SELECT 1 FROM public.user_roles
                     WHERE user_id = auth.uid() AND role = 'admin'))
  WITH CHECK (bucket_id = 'signed-contracts'
              AND EXISTS (SELECT 1 FROM public.user_roles
                          WHERE user_id = auth.uid() AND role = 'admin'));

NOTIFY pgrst, 'reload schema';

COMMIT;
