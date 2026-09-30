-- CMS-855I Enrollment tool (enrollment.html) — providers table + docs bucket
-- ==========================================================================
-- Ports the user's local Flask "CMS-855I form filler" into the portal.
-- One row per provider being enrolled: identity/license fields, PECOS +
-- mailing workflow, and pointers to uploaded ID documents. The PDF itself
-- is filled in the browser (pdf-lib) — nothing generated is stored here.
--
-- SENSITIVITY: payload holds SSN + DOB, and the bucket holds SSN card /
-- driver's license / professional license images. Everything is ADMIN-ONLY
-- (RLS + storage policies), same posture as staff_pay_reviews (migration
-- 41) and strata-medb-pdfs (migration 39). This replaces loose JSON files
-- and images on a desktop PC — strictly better custody.
--
-- Idempotent — safe to re-run. Run after 68_completed_service_boot_rpcs.sql.

BEGIN;

-- ── 1. Providers table ────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.cms855i_providers (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  first_name      TEXT NOT NULL DEFAULT '',
  last_name       TEXT NOT NULL DEFAULT '',
  discipline      TEXT NOT NULL DEFAULT 'PT',      -- PT | OT
  progress_status TEXT NOT NULL DEFAULT 'New',     -- New/In Progress/Waiting on Docs/Ready to Generate/Generated/Submitted/Hold
  pecos_status    TEXT NOT NULL DEFAULT 'Pending', -- Pending/In Progress/Rejected/Completed
  payload         JSONB NOT NULL DEFAULT '{}'::jsonb, -- all semantic form fields (ssn, dob, license, PECOS tracking, notes, ...)
  doc_slots       JSONB NOT NULL DEFAULT '{}'::jsonb, -- slot_key -> storage path in cms855i-docs
  last_updated    TIMESTAMPTZ NOT NULL DEFAULT now(),
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  created_by      UUID
);

COMMENT ON TABLE public.cms855i_providers IS
  'CMS-855I enrollment tracker (enrollment.html). payload = semantic form fields incl. SSN/DOB (admin-only). doc_slots maps document slots to paths in the private cms855i-docs bucket.';

CREATE INDEX IF NOT EXISTS idx_cms855i_providers_updated
  ON public.cms855i_providers (last_updated DESC);

ALTER TABLE public.cms855i_providers ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "cms855i_providers_admin_all" ON public.cms855i_providers;
CREATE POLICY "cms855i_providers_admin_all" ON public.cms855i_providers
  FOR ALL TO authenticated
  USING      (EXISTS (SELECT 1 FROM public.user_roles WHERE user_id = auth.uid() AND role = 'admin'))
  WITH CHECK (EXISTS (SELECT 1 FROM public.user_roles WHERE user_id = auth.uid() AND role = 'admin'));

-- ── 2. Private documents bucket (admin read + write only) ────────────
INSERT INTO storage.buckets (id, name, public)
VALUES ('cms855i-docs', 'cms855i-docs', false)
ON CONFLICT (id) DO NOTHING;

DROP POLICY IF EXISTS "cms855i_docs_admin_read"  ON storage.objects;
DROP POLICY IF EXISTS "cms855i_docs_admin_write" ON storage.objects;

CREATE POLICY "cms855i_docs_admin_read" ON storage.objects
  FOR SELECT TO authenticated
  USING (bucket_id = 'cms855i-docs'
         AND EXISTS (SELECT 1 FROM public.user_roles WHERE user_id = auth.uid() AND role = 'admin'));

CREATE POLICY "cms855i_docs_admin_write" ON storage.objects
  FOR ALL TO authenticated
  USING (bucket_id = 'cms855i-docs'
         AND EXISTS (SELECT 1 FROM public.user_roles WHERE user_id = auth.uid() AND role = 'admin'))
  WITH CHECK (bucket_id = 'cms855i-docs'
              AND EXISTS (SELECT 1 FROM public.user_roles WHERE user_id = auth.uid() AND role = 'admin'));

NOTIFY pgrst, 'reload schema';

COMMIT;
