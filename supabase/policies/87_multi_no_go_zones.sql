-- ════════════════════════════════════════════════════════════════════
-- 87 · Multiple no-go zones per clinician (upgrades migration 86)
--
-- 86 keyed clinician_no_go_zones by clinician_id — one polygon each.
-- This converts the table to one row PER ZONE (UUID id PK, clinician_id
-- indexed), so a clinician can carry several boundaries, each with up
-- to 6 corners. Existing single-zone rows survive as that clinician's
-- first zone. Safe to run whether or not 86 was ever applied (the
-- CREATE below builds the table fresh in that case), and re-runnable.
-- ════════════════════════════════════════════════════════════════════
BEGIN;

CREATE TABLE IF NOT EXISTS public.clinician_no_go_zones (
  clinician_id     UUID NOT NULL REFERENCES public.clinician_v2(id) ON DELETE CASCADE,
  points           JSONB NOT NULL,   -- [{lat, lng}] · 3-6 corners
  updated_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_by_email TEXT
);

ALTER TABLE public.clinician_no_go_zones
  ADD COLUMN IF NOT EXISTS id UUID NOT NULL DEFAULT gen_random_uuid();
ALTER TABLE public.clinician_no_go_zones
  ADD COLUMN IF NOT EXISTS label TEXT;

-- Re-key: PK moves from clinician_id (86) to id. Only runs when the
-- current PK is not already on id, so re-running is a no-op.
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
      FROM pg_index i
      JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = ANY (i.indkey)
     WHERE i.indrelid = 'public.clinician_no_go_zones'::regclass
       AND i.indisprimary
       AND a.attname = 'id'
  ) THEN
    ALTER TABLE public.clinician_no_go_zones DROP CONSTRAINT IF EXISTS clinician_no_go_zones_pkey;
    ALTER TABLE public.clinician_no_go_zones ADD PRIMARY KEY (id);
  END IF;
END $$;

CREATE INDEX IF NOT EXISTS cngz_clinician_idx
  ON public.clinician_no_go_zones (clinician_id, updated_at);

-- RLS identical to 86 (restated so this migration stands alone).
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
