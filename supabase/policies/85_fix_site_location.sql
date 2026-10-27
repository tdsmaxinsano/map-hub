-- ════════════════════════════════════════════════════════════════════
-- 85 · fix_site_location: correct a mis-geocoded service site
--
-- The completed-services import geocodes patient addresses with Mapbox
-- and used to take the first hit blindly — "N. Lakeshore Dr, Chicago"
-- landed 33 miles away in the wrong town. The pin lives on EVERY
-- matching therapy_boss_completed_service_import_rows row AND in the
-- therapy_boss_address_geocode_cache, so this RPC fixes both: rows are
-- re-pointed, and the cache row is overwritten (provider 'manual_fix',
-- quality 'verified') so future re-imports keep the correction.
--
-- Called from the territory planner's 📍 Fix location / 🧭 Verify
-- locations (admin or editor — same gate as site exclusions, mig 61).
-- The client passes the normalized cache key it computed with its own
-- normalizeGeocodeAddressKey so the two normalizations cannot drift.
-- Idempotent (CREATE OR REPLACE). Returns the number of rows updated.
-- ════════════════════════════════════════════════════════════════════
BEGIN;

CREATE OR REPLACE FUNCTION public.fix_site_location(
  p_full_address        TEXT,
  p_street              TEXT,
  p_city                TEXT,
  p_zip                 TEXT,
  p_normalized_address  TEXT,
  p_lat                 DOUBLE PRECISION,
  p_lng                 DOUBLE PRECISION
)
RETURNS INTEGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  updated_rows INTEGER := 0;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM user_roles ur
                 WHERE ur.user_id = auth.uid() AND ur.role IN ('admin','editor')) THEN
    RAISE EXCEPTION 'Only admin or editor may fix site locations';
  END IF;
  IF p_lat IS NULL OR p_lng IS NULL THEN
    RAISE EXCEPTION 'A corrected lat/lng is required';
  END IF;
  IF COALESCE(p_full_address, '') = '' AND COALESCE(p_street, '') = '' THEN
    RAISE EXCEPTION 'An address to match is required';
  END IF;

  IF COALESCE(p_full_address, '') <> '' THEN
    UPDATE therapy_boss_completed_service_import_rows
       SET patient_lat = p_lat, patient_lng = p_lng
     WHERE full_address = p_full_address;
  ELSE
    UPDATE therapy_boss_completed_service_import_rows
       SET patient_lat = p_lat, patient_lng = p_lng
     WHERE street = p_street AND city = p_city
       AND COALESCE(zip_code, '') = COALESCE(p_zip, '');
  END IF;
  GET DIAGNOSTICS updated_rows = ROW_COUNT;

  -- Keep the correction across future imports.
  IF COALESCE(p_normalized_address, '') <> '' THEN
    INSERT INTO therapy_boss_address_geocode_cache
      (normalized_address, full_address, lat, lng, provider, quality, updated_at)
    VALUES
      (p_normalized_address, COALESCE(p_full_address, p_street || ', ' || p_city), p_lat, p_lng,
       'manual_fix', 'verified', NOW())
    ON CONFLICT (normalized_address) DO UPDATE
      SET lat = EXCLUDED.lat, lng = EXCLUDED.lng,
          full_address = EXCLUDED.full_address,
          provider = 'manual_fix', quality = 'verified', updated_at = NOW();
  END IF;

  RETURN updated_rows;
END $$;

REVOKE ALL ON FUNCTION public.fix_site_location(TEXT, TEXT, TEXT, TEXT, TEXT, DOUBLE PRECISION, DOUBLE PRECISION) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.fix_site_location(TEXT, TEXT, TEXT, TEXT, TEXT, DOUBLE PRECISION, DOUBLE PRECISION) TO authenticated, service_role;

NOTIFY pgrst, 'reload schema';

COMMIT;
