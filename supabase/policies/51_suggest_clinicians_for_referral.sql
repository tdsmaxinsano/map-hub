-- Suggest clinicians for a referral — shared SECURITY DEFINER RPC
-- =====================================================================
-- Powers the subtractive "Suggested clinicians" tray in referrals.html
-- (and is a candidate to later back the map's client-side engine too).
-- For a referral (lat/lng + ZIP + disciplines + agency) it returns the
-- ranked-candidate INPUTS; the client does the final ranking so it stays
-- identical to the map's tool (distance-band → rating → distance → name).
--
-- Two signals, unioned per clinician:
--   • Radius  — completed a visit within 2.5 mi of the referral, from
--     therapy_boss_completed_service_import_rows (per-visit patient_lat/lng)
--     joined to ..._import_clinicians for "who served".
--   • ZIP     — covers the referral's ZIP via clinician_zip_coverages.
-- Enriched with clinician_v2 (name/discipline/active/home lat-lng) +
-- clinician_profiles (internal_rating / restrictions / do_not_rehire).
--
-- The "who served" link (matched_clinician_id) is frequently NULL — the
-- map patches it with client-side name matching, so we reproduce that
-- with a normalize_clinician_name() fallback join or the radius half
-- would under-count.
--
-- RLS: authenticated-accessible (the referral board is coordinator-facing,
-- not admin-only; all source tables already carry phase1_authenticated_all).
-- Depends on normalize_agency_name() from migration 30 (in production).
-- Idempotent. Run AFTER 30_agency_contracts.sql.

BEGIN;

-- ── Name normalizer — mirrors the map's clinLookupKeyMap (13493) ──────
-- lower → strip ONE trailing credential code → drop punctuation →
-- collapse whitespace. Used to match TB's parsed clinician names against
-- clinician_v2.name when matched_clinician_id is NULL.
CREATE OR REPLACE FUNCTION public.normalize_clinician_name(name TEXT)
RETURNS TEXT
LANGUAGE sql IMMUTABLE AS $$
  SELECT NULLIF(
    TRIM(
      REGEXP_REPLACE(                                         -- collapse whitespace
        REGEXP_REPLACE(                                       -- drop . , ' "
          REGEXP_REPLACE(                                     -- strip one trailing credential
            LOWER(COALESCE(name, '')),
            '\s+(pt|pta|ot|ota|st|sta|slp|slpa|cota|otr|otrl|rn|lpn|cna|hha|md|do|dpt|np|pa|mspt)\.?\s*$',
            '', 'i'
          ),
          '[.,''"]', '', 'g'
        ),
        '\s+', ' ', 'g'
      )
    ),
    ''
  );
$$;

-- ── Bounding-box index so the radius query is a range scan, not a full
-- table scan (this is the map's heaviest table). Functional index on the
-- ::float8 casts so it matches the query's expressions regardless of the
-- column's stored numeric type. Partial: only geocoded rows. ────────────
CREATE INDEX IF NOT EXISTS idx_tbcsir_patient_latlng
  ON public.therapy_boss_completed_service_import_rows
     ((patient_lat::float8), (patient_lng::float8))
  WHERE patient_lat IS NOT NULL AND patient_lng IS NOT NULL;

-- ── Main RPC ──────────────────────────────────────────────────────────
-- RETURNS TABLE shape may evolve; DROP first so a re-run with a changed
-- signature doesn't hit 42P13 (cannot change return type of existing fn).
DROP FUNCTION IF EXISTS public.suggest_clinicians_for_referral(FLOAT8, FLOAT8, TEXT, TEXT[], TEXT);

CREATE FUNCTION public.suggest_clinicians_for_referral(
  p_lat         FLOAT8,
  p_lng         FLOAT8,
  p_zip         TEXT   DEFAULT NULL,
  p_disciplines TEXT[] DEFAULT NULL,
  p_agency      TEXT   DEFAULT NULL
)
RETURNS TABLE(
  clinician_id          UUID,
  name                  TEXT,
  discipline            TEXT,
  active                BOOLEAN,
  covers_zip            BOOLEAN,
  served_nearby         BOOLEAN,
  nearest_miles         NUMERIC,
  nearby_visits         INTEGER,
  last_served           TEXT,
  home_miles            NUMERIC,
  internal_rating       INTEGER,
  restricted_agencies   JSONB,
  restricted_clinicians JSONB,
  do_not_rehire         BOOLEAN,
  agency_conflict       BOOLEAN
)
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
WITH params AS (
  SELECT
    p_lat AS lat,
    p_lng AS lng,
    NULLIF(TRIM(p_zip), '') AS zip,
    CASE
      WHEN p_disciplines IS NULL OR array_length(p_disciplines, 1) IS NULL THEN NULL
      ELSE (SELECT array_agg(UPPER(TRIM(d))) FROM unnest(p_disciplines) d)
    END AS discs,
    normalize_agency_name(p_agency) AS agency_norm
),
-- Per-visit distances (haversine written once), clinician resolved by
-- matched_clinician_id or the normalized-name fallback.
visit_dist AS (
  SELECT
    COALESCE(c.matched_clinician_id, cvf.id) AS clinician_id,
    3959 * acos(LEAST(1, GREATEST(-1,
      cos(radians(pr.lat)) * cos(radians(r.patient_lat::float8)) *
      cos(radians(r.patient_lng::float8) - radians(pr.lng)) +
      sin(radians(pr.lat)) * sin(radians(r.patient_lat::float8))
    ))) AS dist_mi,
    r.last_visit_date::text AS last_served
  FROM public.therapy_boss_completed_service_import_rows r
  JOIN public.therapy_boss_completed_service_import_clinicians c
    ON c.service_row_id = r.id
  LEFT JOIN public.clinician_v2 cvf
    ON c.matched_clinician_id IS NULL
   AND normalize_clinician_name(COALESCE(NULLIF(c.parsed_clinician_name, ''), c.clinician_name_raw))
       = normalize_clinician_name(cvf.name)
  CROSS JOIN params pr
  WHERE r.patient_lat IS NOT NULL AND r.patient_lng IS NOT NULL
    AND r.patient_lat::float8 BETWEEN pr.lat - 0.04 AND pr.lat + 0.04
    AND r.patient_lng::float8 BETWEEN pr.lng - 0.05 AND pr.lng + 0.05
    AND COALESCE(c.matched_clinician_id, cvf.id) IS NOT NULL
),
radius AS (
  SELECT
    clinician_id,
    MIN(dist_mi)              AS nearest_miles,
    COUNT(*)::INTEGER         AS nearby_visits,
    MAX(last_served)          AS last_served
  FROM visit_dist
  WHERE dist_mi <= 2.5
  GROUP BY clinician_id
),
zipset AS (
  SELECT DISTINCT z.clinician_id
  FROM public.clinician_zip_coverages z
  CROSS JOIN params pr
  WHERE pr.zip IS NOT NULL
    AND z.zip_code = pr.zip
    AND z.clinician_id IS NOT NULL
),
ids AS (
  SELECT clinician_id FROM radius
  UNION
  SELECT clinician_id FROM zipset
)
SELECT
  cv.id,
  cv.name,
  cv.discipline,
  cv.active,
  (zs.clinician_id IS NOT NULL)                                   AS covers_zip,
  (rad.clinician_id IS NOT NULL)                                  AS served_nearby,
  ROUND(rad.nearest_miles::numeric, 2)                           AS nearest_miles,
  rad.nearby_visits,
  rad.last_served,
  CASE WHEN cv.lat IS NOT NULL AND cv.lng IS NOT NULL THEN
    ROUND((3959 * acos(LEAST(1, GREATEST(-1,
      cos(radians(pr.lat)) * cos(radians(cv.lat::float8)) *
      cos(radians(cv.lng::float8) - radians(pr.lng)) +
      sin(radians(pr.lat)) * sin(radians(cv.lat::float8))
    ))))::numeric, 2)
  END                                                             AS home_miles,
  cp.internal_rating::int                                        AS internal_rating,
  COALESCE(cp.restrictions -> 'agencies',   '[]'::jsonb)          AS restricted_agencies,
  COALESCE(cp.restrictions -> 'clinicians', '[]'::jsonb)          AS restricted_clinicians,
  COALESCE(cp.do_not_rehire, false)                              AS do_not_rehire,
  (
    pr.agency_norm IS NOT NULL
    AND EXISTS (
      SELECT 1
      FROM jsonb_array_elements_text(COALESCE(cp.restrictions -> 'agencies', '[]'::jsonb)) ra
      WHERE normalize_agency_name(ra) = pr.agency_norm
    )
  )                                                               AS agency_conflict
FROM ids
JOIN public.clinician_v2 cv          ON cv.id = ids.clinician_id
LEFT JOIN public.clinician_profiles cp ON cp.clinician_id = cv.id
LEFT JOIN radius rad                 ON rad.clinician_id = cv.id
LEFT JOIN zipset zs                  ON zs.clinician_id = cv.id
CROSS JOIN params pr
WHERE cv.active IS DISTINCT FROM false                            -- drop inactive
  AND (
    pr.discs IS NULL
    OR UPPER(TRIM(cv.discipline)) = ANY (pr.discs)
  );
$$;

REVOKE ALL ON FUNCTION public.suggest_clinicians_for_referral(FLOAT8, FLOAT8, TEXT, TEXT[], TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.suggest_clinicians_for_referral(FLOAT8, FLOAT8, TEXT, TEXT[], TEXT) TO authenticated;

REVOKE ALL ON FUNCTION public.normalize_clinician_name(TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.normalize_clinician_name(TEXT) TO authenticated;

COMMIT;

NOTIFY pgrst, 'reload schema';
