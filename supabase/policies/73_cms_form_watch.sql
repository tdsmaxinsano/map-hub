-- ════════════════════════════════════════════════════════════════════
-- 73 · CMS form watch — detect when Medicare revises the CMS-855I
--
-- One row per watched form. The cms-form-watch Edge Function (service
-- role) fetches the official CMS PDF at most once per 6 days, stores a
-- SHA-256 of the bytes, and compares it to the acknowledged baseline.
-- enrollment.html shows a banner when they differ; an admin's ✓ Mark
-- current button moves the baseline forward.
--
-- The watched URL lives in DATA so a CMS link move is a one-line
-- UPDATE, not a function redeploy. Idempotent.
-- ════════════════════════════════════════════════════════════════════
BEGIN;

CREATE TABLE IF NOT EXISTS public.cms_form_watch (
  form_key              TEXT PRIMARY KEY,
  url                   TEXT NOT NULL,
  label                 TEXT,
  current_hash          TEXT,          -- SHA-256 of the latest fetched CMS copy
  current_size          BIGINT,
  current_last_modified TEXT,          -- CMS's Last-Modified header, verbatim
  acknowledged_hash     TEXT,          -- the revision our template matches
  changed_detected_at   TIMESTAMPTZ,   -- set when current != acknowledged
  last_checked_at       TIMESTAMPTZ,
  last_error            TEXT,
  acknowledged_at       TIMESTAMPTZ,
  acknowledged_by       UUID
);

INSERT INTO public.cms_form_watch (form_key, url, label)
VALUES ('cms855i',
        'https://www.cms.gov/medicare/cms-forms/cms-forms/downloads/cms855i.pdf',
        'CMS-855I enrollment application')
ON CONFLICT (form_key) DO NOTHING;

ALTER TABLE public.cms_form_watch ENABLE ROW LEVEL SECURITY;

-- Admin + editor can read the state (the Med B CR page renders it).
DROP POLICY IF EXISTS "cms_form_watch_staff_read" ON public.cms_form_watch;
CREATE POLICY "cms_form_watch_staff_read" ON public.cms_form_watch
  FOR SELECT TO authenticated
  USING (EXISTS (SELECT 1 FROM public.user_roles
                 WHERE user_id = auth.uid() AND role IN ('admin', 'editor')));

-- Only admins can move the baseline (✓ Mark current). The Edge Function
-- writes with the service role and bypasses RLS.
DROP POLICY IF EXISTS "cms_form_watch_admin_update" ON public.cms_form_watch;
CREATE POLICY "cms_form_watch_admin_update" ON public.cms_form_watch
  FOR UPDATE TO authenticated
  USING      (EXISTS (SELECT 1 FROM public.user_roles
                      WHERE user_id = auth.uid() AND role = 'admin'))
  WITH CHECK (EXISTS (SELECT 1 FROM public.user_roles
                      WHERE user_id = auth.uid() AND role = 'admin'));

NOTIFY pgrst, 'reload schema';

COMMIT;
