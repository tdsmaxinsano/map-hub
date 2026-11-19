-- ════════════════════════════════════════════════════════════════════
-- 99 · Saved COI contact emails per vendor (Finance → 🛡 Insurance → 📤)
--
-- One row per vendor (an agency from home_health_agencies or a custom
-- name) holding the email(s) the certificate of insurance goes to.
-- The 📤 Send panel fills the emails from here, saves any change on
-- send / log, and has a 💾 Save emails button to update them without
-- sending anything.
--
-- vendor_key = lower(trim(vendor_name)) — the upsert conflict target.
-- agency_name is the home_health_agencies name when picked from the
-- agency list (text, no FK — agencies can be renamed / merged).
--
-- RLS: admin-only (same as migrations 54 / 97 / 98). Idempotent.
-- ════════════════════════════════════════════════════════════════════
BEGIN;

CREATE TABLE IF NOT EXISTS public.insurance_vendor_contacts (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  vendor_key  TEXT NOT NULL UNIQUE,
  vendor_name TEXT NOT NULL,
  is_agency   BOOLEAN NOT NULL DEFAULT false,
  emails      TEXT[] NOT NULL DEFAULT '{}',
  notes       TEXT,
  updated_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_by  UUID
);

ALTER TABLE public.insurance_vendor_contacts ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "insurance_vendor_contacts_admin_all" ON public.insurance_vendor_contacts;
CREATE POLICY "insurance_vendor_contacts_admin_all" ON public.insurance_vendor_contacts
  FOR ALL TO authenticated
  USING (EXISTS (SELECT 1 FROM public.user_roles ur
                 WHERE ur.user_id = auth.uid() AND ur.role = 'admin'))
  WITH CHECK (EXISTS (SELECT 1 FROM public.user_roles ur
                      WHERE ur.user_id = auth.uid() AND ur.role = 'admin'));

-- Seed from anything already sent / logged (latest recipients per vendor).
INSERT INTO public.insurance_vendor_contacts (vendor_key, vendor_name, emails, updated_at)
SELECT DISTINCT ON (lower(trim(s.vendor_name)))
       lower(trim(s.vendor_name)), trim(s.vendor_name), s.recipients, s.sent_at
FROM public.company_insurance_sends s
WHERE coalesce(trim(s.vendor_name), '') <> '' AND cardinality(s.recipients) > 0
ORDER BY lower(trim(s.vendor_name)), s.sent_at DESC
ON CONFLICT (vendor_key) DO NOTHING;

NOTIFY pgrst, 'reload schema';

COMMIT;
