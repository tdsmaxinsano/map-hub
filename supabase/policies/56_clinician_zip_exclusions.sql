-- Clinician "Won't serve" ZIPs — area refusals, recognized at staffing time
-- =====================================================================
-- Therapists sometimes refuse specific areas ("I no longer do Skokie").
-- That's DIFFERENT from a move: it's area-specific while the rest of
-- their territory stays, so the time-based Ignore-History-Before cutoff
-- is the wrong tool — and cleaning TB ZIPs alone doesn't stop the
-- suggest engines from recommending them via the 2.5-mi served-history
-- signal (they've worked there, so they keep ranking).
--
--   clinician_zip_exclusions — one row per (clinician, refused ZIP),
--   with a note ("told us 8/19 — no more Skokie") + who/when. Managed
--   from the Territory Planner's ⛔ Won't-serve card.
--
-- Recognition: suggest_clinicians_for_referral is REBUILT to return
-- zip_excluded BOOLEAN (the referral's ZIP is on the candidate's refusal
-- list). The referral tray treats it like an agency restriction (#201):
-- ⛔ flag, Accept replaced by the 🔓 lift-request, commit + manual Add
-- refuse. The map's 🔎 Suggest panel flags it. Enforcement per user:
-- block + lift request — "the therapist said no" gets at least agency-
-- restriction-level protection.
--
-- RLS: SELECT authenticated; writes admin+editor (12_evaluation_
-- compliance template). Idempotent — safe to re-run.
-- Run after 55_clinician_zip_plans.sql.

BEGIN;

-- ── 1. Table ─────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.clinician_zip_exclusions (
  clinician_id  UUID NOT NULL REFERENCES public.clinician_v2(id) ON DELETE CASCADE,
  zip_code      TEXT NOT NULL,
  note          TEXT,
  set_by_email  TEXT,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (clinician_id, zip_code)
);

COMMENT ON TABLE public.clinician_zip_exclusions IS
  'Areas a clinician refuses to serve ("won''t serve" ZIPs). Suggest engines flag + block dispatch for referrals in these ZIPs; managed from the Territory Planner.';

ALTER TABLE public.clinician_zip_exclusions ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "zip_excl_select_auth"        ON public.clinician_zip_exclusions;
DROP POLICY IF EXISTS "zip_excl_write_editor_admin" ON public.clinician_zip_exclusions;

CREATE POLICY "zip_excl_select_auth" ON public.clinician_zip_exclusions
  FOR SELECT TO authenticated USING (true);

CREATE POLICY "zip_excl_write_editor_admin" ON public.clinician_zip_exclusions
  FOR ALL TO authenticated
  USING      (EXISTS (SELECT 1 FROM public.user_roles ur
                      WHERE ur.user_id = auth.uid() AND ur.role IN ('admin','editor')))
  WITH CHECK (EXISTS (SELECT 1 FROM public.user_roles ur
                      WHERE ur.user_id = auth.uid() AND ur.role IN ('admin','editor')));

-- ── 2. Rebuild the suggest RPC with zip_excluded ─────────────────────
-- Return shape changes (new column) → DROP first to avoid 42P13. Body is
-- migration 53's (map-mirroring window + name matcher + inactive
-- returned) plus one LEFT JOIN + output column.
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
  agency_conflict       BOOLEAN,
  zip_excluded          BOOLEAN
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
  )                                                               AS agency_conflict,
  (zx.clinician_id IS NOT NULL)                                   AS zip_excluded
FROM ids
JOIN public.clinician_v2 cv          ON cv.id = ids.clinician_id
LEFT JOIN public.clinician_profiles cp ON cp.clinician_id = cv.id
LEFT JOIN radius rad                 ON rad.clinician_id = cv.id
LEFT JOIN zipset zs                  ON zs.clinician_id = cv.id
CROSS JOIN params pr
-- "Won't serve" — the referral's ZIP is on the candidate's refusal list.
LEFT JOIN public.clinician_zip_exclusions zx
  ON zx.clinician_id = cv.id AND pr.zip IS NOT NULL AND zx.zip_code = pr.zip
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

COMMIT;

NOTIFY pgrst, 'reload schema';
