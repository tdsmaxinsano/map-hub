-- ════════════════════════════════════════════════════════════════════
-- 70 · CMS-855I enrollment — open to EDITORS as well as admins
--
-- The enrollment tool (enrollment.html, "Med B CR" from Roster Review)
-- shipped admin-only (migration 69). Editors now get day-to-day use:
-- providers, document uploads, AI prefill, PDF generation, progress
-- board. The client keeps the desktop-backup import + duplicate-cleanup
-- buttons admin-only, but data access is role-gated here: both the
-- cms855i_providers table and the private cms855i-docs bucket accept
-- admin OR editor. Readonly users remain fully excluded.
--
-- Idempotent — drops the migration-69 policy names and these names
-- before recreating. Run from the Supabase SQL editor.
-- ════════════════════════════════════════════════════════════════════
BEGIN;

-- ── 1. Providers table: admin+editor for everything ──────────────────
DROP POLICY IF EXISTS "cms855i_providers_admin_all"  ON public.cms855i_providers;
DROP POLICY IF EXISTS "cms855i_providers_staff_all"  ON public.cms855i_providers;
CREATE POLICY "cms855i_providers_staff_all" ON public.cms855i_providers
  FOR ALL TO authenticated
  USING      (EXISTS (SELECT 1 FROM public.user_roles
                      WHERE user_id = auth.uid() AND role IN ('admin', 'editor')))
  WITH CHECK (EXISTS (SELECT 1 FROM public.user_roles
                      WHERE user_id = auth.uid() AND role IN ('admin', 'editor')));

-- ── 2. Private documents bucket: admin+editor read + write ───────────
DROP POLICY IF EXISTS "cms855i_docs_admin_read"  ON storage.objects;
DROP POLICY IF EXISTS "cms855i_docs_admin_write" ON storage.objects;
DROP POLICY IF EXISTS "cms855i_docs_staff_read"  ON storage.objects;
DROP POLICY IF EXISTS "cms855i_docs_staff_write" ON storage.objects;

CREATE POLICY "cms855i_docs_staff_read" ON storage.objects
  FOR SELECT TO authenticated
  USING (bucket_id = 'cms855i-docs'
         AND EXISTS (SELECT 1 FROM public.user_roles
                     WHERE user_id = auth.uid() AND role IN ('admin', 'editor')));

CREATE POLICY "cms855i_docs_staff_write" ON storage.objects
  FOR ALL TO authenticated
  USING (bucket_id = 'cms855i-docs'
         AND EXISTS (SELECT 1 FROM public.user_roles
                     WHERE user_id = auth.uid() AND role IN ('admin', 'editor')))
  WITH CHECK (bucket_id = 'cms855i-docs'
              AND EXISTS (SELECT 1 FROM public.user_roles
                          WHERE user_id = auth.uid() AND role IN ('admin', 'editor')));

NOTIFY pgrst, 'reload schema';

COMMIT;
