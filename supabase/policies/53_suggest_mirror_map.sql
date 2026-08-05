-- Suggest RPC mirrors the Map (master): recent-history window + map's
-- name matcher + inactive returned for client-side toggling
-- =====================================================================
-- The map's 🔎 Suggest tool is the MASTER staffing engine; the referral
-- board's tray (this RPC, migration 51/52) must produce the SAME list.
-- Three divergences reconciled here:
--
--  1. HISTORY WINDOW — the map's boot load only fetches completed-service
--     rows in a recent window: cutoff = JANUARY 1 of (currentYear − 1)
--     (getCompletedServiceRecentCutoffIsoDate, calendar-anchored, NOT
--     "today − 2 years"), where a row qualifies if ANY of last_visit_date /
--     ended_date / start_of_episode / referral_date >= cutoff (row-level
--     OR, mirroring the boot query's .or() filter). The RPC previously
--     searched ALL history, surfacing extra candidates + closer distances
--     the map never shows. Same window now applied in visit_dist.
--
--  2. NAME MATCHER — normalize_clinician_name stripped a long credential
--     list but could NOT match "Last, First" against "First Last", so
--     visits the map attributes via its name-variant matcher were missed
--     here (e.g. Adam Ouyang's nearest visit). Rebuilt to mirror the map:
--     strip ONE trailing PT/PTA/OT/OTA credential (parseCompletedService-
--     ClinicianName's regex), lowercase, non-alphanumerics → space, then
--     SORT THE NAME TOKENS — a sorted-token key equals-compare covers all
--     of the map's variants (comma-swap "doe, jane"→"jane doe" and
--     last-token rotation) in one deterministic form.
--
--  3. INACTIVE — the map includes Inactive clinicians; the RPC dropped
--     them. Per the user: default-HIDE with a "Show inactive" toggle on
--     both surfaces. The RPC now RETURNS inactive candidates too (the
--     `active` column is already in the return shape) and the clients
--     filter — so the toggle needs no server round-trip.
--
-- Unchanged: signature + return shape (no client query changes needed),
-- the per-clinician "Ignore History Before" filter (migration 51 fix era),
-- haversine guards, restrictions/rating enrichment, ranking inputs.
-- Known residual: for ZIP-only candidates the map's fallback distance uses
-- its Work/Home pin mode (a per-browser setting); the RPC uses home
-- coords. Affects only the tiebreak of not-served-nearby candidates.
--
-- Idempotent. Run after 52_suggestion_triage.sql.

BEGIN;

-- ── 1. Map-mirroring name normalizer ─────────────────────────────────
-- Mirrors clinician-map.html parseCompletedServiceClinicianName (trailing
-- credential regex) + normalizeImportedClinicianName (lowercase, non-
-- alphanumeric → space, collapse) + getImportedClinicianNameVariants
-- (comma-swap / token-rotation — subsumed by sorting the tokens).
CREATE OR REPLACE FUNCTION public.normalize_clinician_name(name TEXT)
RETURNS TEXT
LANGUAGE sql IMMUTABLE AS $$
  SELECT NULLIF(
    array_to_string(ARRAY(
      SELECT t
      FROM unnest(string_to_array(
        TRIM(REGEXP_REPLACE(
          REGEXP_REPLACE(
            REGEXP_REPLACE(
              LOWER(COALESCE(name, '')),
              '\s+(pta|pt|ota|ot)\.?\s*$', '', 'i'
            ),
            '[^a-z0-9\s]+', ' ', 'g'
          ),
          '\s+', ' ', 'g'
        )), ' ')) t
      WHERE t <> ''
      ORDER BY t
    ), ' '),
    ''
  );
$$;

-- ── 2. Rebuild the RPC with the mirrored rules ───────────────────────
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
    normalize_agency_name(p_agency) AS agency_norm,
    -- Map's boot-load window: January 1 of (currentYear − 1). ISO text so
    -- the LEFT(...,10) compares work for DATE or ISO-text columns alike.
    ((date_trunc('year', CURRENT_DATE) - interval '1 year')::date)::text AS win_cutoff
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
  -- "Ignore History Before" (map profile → clinician_profiles.tags JSONB;
  -- the map's JS calls this column profile_tags in memory): when a
  -- clinician moved, visits anchored before their cutoff must not count
  -- toward proximity. Anchor mirrors the map's
  -- getCompletedServiceCoverageAnchorDate (start_of_episode → referral_date
  -- → last_visit_date → ended_date); rows with no anchor stay eligible,
  -- matching the JS coverage tools. ISO text compare = chronological.
  LEFT JOIN public.clinician_profiles cpf
    ON cpf.clinician_id = COALESCE(c.matched_clinician_id, cvf.id)
  CROSS JOIN params pr
  CROSS JOIN LATERAL (
    SELECT
      CASE WHEN COALESCE(cpf.tags ->> 'ignoreHistoryBefore',
                         cpf.tags ->> 'ignore_history_before')
                ~ '^\d{4}-\d{2}-\d{2}'
           THEN LEFT(COALESCE(cpf.tags ->> 'ignoreHistoryBefore',
                              cpf.tags ->> 'ignore_history_before'), 10)
      END AS cutoff,
      LEFT(COALESCE(r.start_of_episode::text, r.referral_date::text,
                    r.last_visit_date::text, r.ended_date::text), 10) AS anchor
  ) hx
  WHERE r.patient_lat IS NOT NULL AND r.patient_lng IS NOT NULL
    AND r.patient_lat::float8 BETWEEN pr.lat - 0.04 AND pr.lat + 0.04
    AND r.patient_lng::float8 BETWEEN pr.lng - 0.05 AND pr.lng + 0.05
    AND COALESCE(c.matched_clinician_id, cvf.id) IS NOT NULL
    AND (hx.cutoff IS NULL OR hx.anchor IS NULL OR hx.anchor >= hx.cutoff)
    -- Map's recent-history window (row-level OR over the same 4 date
    -- columns the boot query filters on — a row qualifies if ANY date is
    -- on/after Jan 1 of last year).
    AND (
         LEFT(r.last_visit_date::text, 10)  >= pr.win_cutoff
      OR LEFT(r.ended_date::text, 10)       >= pr.win_cutoff
      OR LEFT(r.start_of_episode::text, 10) >= pr.win_cutoff
      OR LEFT(r.referral_date::text, 10)    >= pr.win_cutoff
    )
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
  -- Guard BOTH endpoints: with a NULL referral lat/lng (ZIP-only match on an
  -- un-geocoded referral) the inner expression is NULL, and Postgres's
  -- GREATEST(-1, NULL) IGNORES the NULL → acos(-1) → a bogus ~12,437 mi.
  CASE WHEN pr.lat IS NOT NULL AND pr.lng IS NOT NULL
        AND cv.lat IS NOT NULL AND cv.lng IS NOT NULL THEN
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
    -- jsonb_typeof guard: a malformed restrictions.agencies (scalar instead
    -- of array) would otherwise error the WHOLE query for every caller.
    AND jsonb_typeof(COALESCE(cp.restrictions -> 'agencies', '[]'::jsonb)) = 'array'
    AND EXISTS (
      SELECT 1
      FROM jsonb_array_elements_text(cp.restrictions -> 'agencies') ra
      WHERE normalize_agency_name(ra) = pr.agency_norm
    )
  )                                                               AS agency_conflict
FROM ids
JOIN public.clinician_v2 cv          ON cv.id = ids.clinician_id
LEFT JOIN public.clinician_profiles cp ON cp.clinician_id = cv.id
LEFT JOIN radius rad                 ON rad.clinician_id = cv.id
LEFT JOIN zipset zs                  ON zs.clinician_id = cv.id
CROSS JOIN params pr
-- NOTE: no active filter — Inactive clinicians are returned (map is the
-- master and includes them); clients default-hide them behind the
-- "Show inactive" toggle.
WHERE (
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
