-- ════════════════════════════════════════════════════════════════════
-- 86 · Clinician no-go zones (requires migration 56)
--
-- The territory planner gains a drawn boundary (up to 6 draggable
-- corners, light-red translucent) marking a hard no-go area for one
-- clinician. The polygon itself lives here so it redraws editable on
-- every visit. Accepting the zone writes the ZIPs inside it into the
-- EXISTING clinician_zip_exclusions table with note 'No-go zone' —
-- which the planner badges, the main map's 🔎 Suggest panel, the
-- suggest RPCs (migrations 56/57) and referral dispatch blocking all
-- already read — so the zone takes effect portal-wide with no other
-- changes. Zone-derived rows are recognizable by their note, so
-- re-accepting after moving a corner can release stale ZIPs without
-- ever touching hand-set won't-serve rows.
--
-- RLS mirrors migration 56: everyone signed-in reads, admin/editor
-- writes. Idempotent.
-- ════════════════════════════════════════════════════════════════════
BEGIN;

CREATE TABLE IF NOT EXISTS public.clinician_no_go_zones (
  clinician_id     UUID PRIMARY KEY REFERENCES public.clinician_v2(id) ON DELETE CASCADE,
  points           JSONB NOT NULL,   -- [{lat, lng}] · 3-6 corners
  updated_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_by_email TEXT
);

ALTER TABLE public.clinician_no_go_zones ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "cngz_read" ON public.clinician_no_go_zones;
CREATE POLICY "cngz_read" ON public.clinician_no_go_zones
  FOR SELECT TO authenticated USING (true);

DROP POLICY IF EXISTS "cngz_write" ON public.clinician_no_go_zones;
CREATE POLICY "cngz_write" ON public.clinician_no_go_zones
  FOR ALL TO authenticated
  USING (EXISTS (SELECT 1 FROM public.user_roles
                 WHERE user_id = auth.uid() AND role IN ('admin','editor')))
  WITH CHECK (EXISTS (SELECT 1 FROM public.user_roles
                      WHERE user_id = auth.uid() AND role IN ('admin','editor')));

NOTIFY pgrst, 'reload schema';

COMMIT;
