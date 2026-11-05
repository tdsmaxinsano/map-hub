-- ════════════════════════════════════════════════════════════════════
-- 90 · Contract templates bucket (contracts.html)
--
-- Private storage for the tokenized Professional Services Agreement
-- Word master ({{AGENCY_NAME}}, {{RATE_PT}}, …). The template is NEVER
-- committed to git (the repo deploys to Vercel); contracts.html
-- installs it here once via the "Install template" button and fetches
-- it on every Generate. Mirrors the cms855i-docs / parking-receipts
-- posture: private bucket, admin-only object access. Idempotent.
-- ════════════════════════════════════════════════════════════════════
BEGIN;

INSERT INTO storage.buckets (id, name, public)
VALUES ('contract-templates', 'contract-templates', false)
ON CONFLICT (id) DO NOTHING;

DROP POLICY IF EXISTS "contracttpl_admin_all" ON storage.objects;
CREATE POLICY "contracttpl_admin_all" ON storage.objects
  FOR ALL TO authenticated
  USING (bucket_id = 'contract-templates'
         AND EXISTS (SELECT 1 FROM public.user_roles
                     WHERE user_id = auth.uid() AND role = 'admin'))
  WITH CHECK (bucket_id = 'contract-templates'
              AND EXISTS (SELECT 1 FROM public.user_roles
                          WHERE user_id = auth.uid() AND role = 'admin'));

NOTIFY pgrst, 'reload schema';

COMMIT;
