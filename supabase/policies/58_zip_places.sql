-- ZIP → place-name cache — make ZIPs readable ("60176 · Schiller Park")
-- =====================================================================
-- ZIP chips across the Territory Planner and suggest tools read as bare
-- numbers. This adds a tiny shared lookup cache so every ZIP can carry a
-- brief place name. It self-populates client-side from two free sources:
-- the clinician's own visit history (rows already carry city) and the
-- Zippopotam ZIP directory — first page to resolve a ZIP writes it here,
-- every later page (any user) reads it instantly.
--
-- Public-knowledge reference data (ZIP → town), not PHI — so RLS is
-- authenticated read AND write (any signed-in page may fill the cache).
--
-- Precedent: therapy_boss_address_geocode_cache (persisted geocode cache).
-- Idempotent — safe to re-run. Run after 57_clinician_zip_requests.sql.

BEGIN;

CREATE TABLE IF NOT EXISTS public.zip_places (
  zip_code   TEXT PRIMARY KEY,
  place_name TEXT,
  state      TEXT,
  source     TEXT,                -- 'history' | 'zippopotam'
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.zip_places IS
  'Shared ZIP → place-name lookup cache (self-populating from visit-history cities + the Zippopotam directory). Display sugar only — never used for matching.';

ALTER TABLE public.zip_places ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "zip_places_authenticated_all" ON public.zip_places;
CREATE POLICY "zip_places_authenticated_all" ON public.zip_places
  FOR ALL TO authenticated USING (true) WITH CHECK (true);

COMMIT;

NOTIFY pgrst, 'reload schema';
