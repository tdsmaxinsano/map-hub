-- Site exclusions — drop specific visit-history LOCATIONS from territory math
-- ===========================================================================
-- Sometimes a single visit-history location shouldn't register as territory:
-- a one-off favor visit far outside the therapist's real area, a bad
-- geocode, a snowbird patient's second address. The Territory Planner now
-- lets staff right-click a site dot (or use the popup's 🚫 button) to
-- exclude that LOCATION (keyed by its normalized address) for that
-- clinician. Per user decision (Aug 2026) exclusion applies EVERYWHERE:
-- the planner's served-ZIP counts, coverage gaps, work center, and travel
-- stats skip excluded sites, and the roster's Coverage Gaps flag must
-- agree — so this migration also rebuilds list_clinician_coverage_gaps()
-- (migration 60) to apply the same filter server-side.
--
-- Address normalization (must match the planner's siteAddrKey JS):
--   LOWER(TRIM(full_address)) with runs of whitespace collapsed to one
--   space. Address-level, not coordinate-level — a re-geocode doesn't
--   un-exclude a site.
--
-- RLS mirrors the ZIP exclusions table (migration 56): SELECT for all
-- authenticated, writes admin+editor.
--
-- The function body below SUPERSEDES migration 60's — running this alone
-- installs the site-aware version (same return shape, so consumers are
-- unaffected). Idempotent — safe to re-run. Run after 60.

BEGIN;

CREATE TABLE IF NOT EXISTS public.clinician_site_exclusions (
  clinician_id    UUID NOT NULL REFERENCES public.clinician_v2(id) ON DELETE CASCADE,
  address_norm    TEXT NOT NULL,   -- lower/trim/whitespace-collapsed full_address
  address_display TEXT,            -- as shown when excluded (for the manager list)
  note            TEXT,
  set_by_email    TEXT,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (clinician_id, address_norm)
);

COMMENT ON TABLE public.clinician_site_exclusions IS
  'Visit-history locations excluded from territory math per clinician (one-off far visits, bad geocodes). Keyed by normalized address. Read by the Territory Planner and list_clinician_coverage_gaps().';

ALTER TABLE public.clinician_site_exclusions ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "site_excl_select_auth"        ON public.clinician_site_exclusions;
DROP POLICY IF EXISTS "site_excl_write_editor_admin" ON public.clinician_site_exclusions;

CREATE POLICY "site_excl_select_auth" ON public.clinician_site_exclusions
  FOR SELECT TO authenticated USING (true);

CREATE POLICY "site_excl_write_editor_admin" ON public.clinician_site_exclusions
  FOR ALL TO authenticated
  USING      (EXISTS (SELECT 1 FROM public.user_roles ur
                      WHERE ur.user_id = auth.uid() AND ur.role IN ('admin','editor')))
  WITH CHECK (EXISTS (SELECT 1 FROM public.user_roles ur
                      WHERE ur.user_id = auth.uid() AND ur.role IN ('admin','editor')));

-- ── Rebuild list_clinician_coverage_gaps() with the site-exclusion filter ──
-- Full body from migration 60 plus one NOT EXISTS in the episodes CTE.
-- Same return shape → consumers unchanged; DROP-then-CREATE per the
-- house 42P13 rule.

DROP FUNCTION IF EXISTS public.list_clinician_coverage_gaps();

CREATE FUNCTION public.list_clinician_coverage_gaps()
RETURNS TABLE(
  clinician_id          UUID,
  clinician_name        TEXT,
  declared_count        INTEGER,
  served_count          INTEGER,
  gap_add_count         INTEGER,
  gap_idle_count        INTEGER,
  gap_add_refused_count INTEGER,
  gap_add_zips          TEXT[],
  gap_idle_zips         TEXT[]
)
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
WITH
roster_names AS MATERIALIZED (
  SELECT cv.id, normalize_clinician_name(cv.name) AS norm_name
  FROM public.clinician_v2 cv
  WHERE cv.name IS NOT NULL
),
matched_links AS (
  SELECT c.matched_clinician_id AS clinician_id, c.service_row_id, 0 AS src_rank
  FROM public.therapy_boss_completed_service_import_clinicians c
  WHERE c.matched_clinician_id IS NOT NULL
),
name_links AS (
  SELECT rn.id AS clinician_id, c.service_row_id, 1 AS src_rank
  FROM public.therapy_boss_completed_service_import_clinicians c
  JOIN roster_names rn
    ON normalize_clinician_name(
         COALESCE(NULLIF(c.parsed_clinician_name, ''), c.clinician_name_raw)
       ) = rn.norm_name
  WHERE c.matched_clinician_id IS NULL
),
links AS (
  SELECT * FROM matched_links
  UNION ALL
  SELECT * FROM name_links
),
episodes AS (
  SELECT DISTINCT ON (l.clinician_id, ep.dedupe_key)
    l.clinician_id,
    TRIM(COALESCE(r.zip_code, ''))   AS zip_raw,
    r.full_address,
    ep.anchor_raw,
    CASE WHEN ep.anchor_raw ~ '^\d{4}-\d{2}-\d{2}'
         THEN LEFT(ep.anchor_raw, 10) END AS anchor_iso
  FROM links l
  JOIN public.therapy_boss_completed_service_import_rows r ON r.id = l.service_row_id
  CROSS JOIN LATERAL (
    SELECT
      LOWER(TRIM(COALESCE(r.patient_name, ''))) || '|' ||
      UPPER(TRIM(COALESCE(r.service, '')))      || '|' ||
      COALESCE(r.start_of_episode::text, '')    || '|' ||
      COALESCE(r.ended_date::text, '')          || '|' ||
      COALESCE(r.last_visit_date::text, '')     || '|' ||
      COALESCE(r.service_visits::text, '')      || '|' ||
      TRIM(COALESCE(r.zip_code, ''))            AS dedupe_key,
      COALESCE(
        NULLIF(r.start_of_episode::text, ''),
        NULLIF(r.referral_date::text, ''),
        NULLIF(r.last_visit_date::text, ''),
        NULLIF(r.ended_date::text, '')
      ) AS anchor_raw
  ) ep
  -- Site exclusions (migration 61): an excluded LOCATION never registers.
  WHERE NOT EXISTS (
    SELECT 1 FROM public.clinician_site_exclusions se
    WHERE se.clinician_id = l.clinician_id
      AND se.address_norm = LOWER(regexp_replace(TRIM(COALESCE(r.full_address, '')), '\s+', ' ', 'g'))
  )
  ORDER BY l.clinician_id, ep.dedupe_key, l.src_rank, r.created_at, r.id
),
cutoffs AS (
  SELECT cp.clinician_id,
         CASE WHEN x.raw ~ '^\d{4}-\d{2}-\d{2}' THEN LEFT(x.raw, 10) END AS cutoff
  FROM public.clinician_profiles cp
  CROSS JOIN LATERAL (
    SELECT NULLIF(TRIM(COALESCE(
      NULLIF(cp.tags ->> 'ignore_history_before', ''),
      NULLIF(cp.tags ->> 'ignoreHistoryBefore', ''),
      NULLIF(cp.tags ->> 'history_ignore_before', ''),
      NULLIF(cp.tags ->> 'historyIgnoreBefore', '')
    )), '') AS raw
  ) x
  WHERE cp.tags IS NOT NULL
),
served AS (
  SELECT e.clinician_id, z.zip, COUNT(*)::int AS episodes
  FROM episodes e
  LEFT JOIN cutoffs cf ON cf.clinician_id = e.clinician_id
  CROSS JOIN LATERAL (
    SELECT COALESCE(
      NULLIF(e.zip_raw, ''),
      substring(e.full_address FROM '\y(\d{5})\y')
    ) AS zip
  ) z
  WHERE z.zip IS NOT NULL
    AND (cf.cutoff IS NULL
         OR e.anchor_raw IS NULL
         OR (e.anchor_iso IS NOT NULL AND e.anchor_iso >= cf.cutoff))
  GROUP BY e.clinician_id, z.zip
),
declared AS (
  SELECT zc.clinician_id, TRIM(zc.zip_code) AS zip
  FROM public.clinician_zip_coverages zc
  WHERE zc.clinician_id IS NOT NULL
    AND NULLIF(TRIM(zc.zip_code), '') IS NOT NULL
  GROUP BY 1, 2
),
declared_fallback AS (
  SELECT cv.id AS clinician_id, TRIM(z.z) AS zip
  FROM public.clinician_v2 cv
  CROSS JOIN LATERAL unnest(string_to_array(cv.preferred_zips, ',')) AS z(z)
  WHERE NULLIF(TRIM(COALESCE(cv.preferred_zips, '')), '') IS NOT NULL
    AND NULLIF(TRIM(z.z), '') IS NOT NULL
    AND NOT EXISTS (SELECT 1 FROM declared d WHERE d.clinician_id = cv.id)
  GROUP BY 1, 2
),
declared_all AS (
  SELECT * FROM declared
  UNION ALL
  SELECT * FROM declared_fallback
),
gap_add AS (
  SELECT s.clinician_id, s.zip, s.episodes,
         EXISTS (
           SELECT 1 FROM public.clinician_zip_exclusions x
           WHERE x.clinician_id = s.clinician_id AND TRIM(x.zip_code) = s.zip
         ) AS refused
  FROM served s
  WHERE NOT EXISTS (
    SELECT 1 FROM declared_all d
    WHERE d.clinician_id = s.clinician_id AND d.zip = s.zip
  )
),
gap_idle AS (
  SELECT d.clinician_id, d.zip
  FROM declared_all d
  WHERE NOT EXISTS (
    SELECT 1 FROM served s
    WHERE s.clinician_id = d.clinician_id AND s.zip = d.zip
  )
),
ga AS (
  SELECT g.clinician_id,
         (COUNT(*) FILTER (WHERE NOT g.refused))::int AS gap_add_count,
         (COUNT(*) FILTER (WHERE g.refused))::int     AS gap_add_refused_count,
         (ARRAY_AGG(g.zip ORDER BY g.episodes DESC, g.zip ASC)
            FILTER (WHERE NOT g.refused))[1:12]        AS gap_add_zips
  FROM gap_add g
  GROUP BY 1
),
gi AS (
  SELECT g.clinician_id,
         COUNT(*)::int AS gap_idle_count,
         (ARRAY_AGG(g.zip ORDER BY g.zip))[1:12] AS gap_idle_zips
  FROM gap_idle g
  GROUP BY 1
),
dc AS (SELECT d.clinician_id, COUNT(*)::int AS declared_count FROM declared_all d GROUP BY 1),
sc AS (SELECT s.clinician_id, COUNT(*)::int AS served_count   FROM served s       GROUP BY 1),
ids AS (
  SELECT s.clinician_id FROM sc s
  UNION
  SELECT d.clinician_id FROM dc d
)
SELECT
  cv.id                                  AS clinician_id,
  cv.name                                AS clinician_name,
  COALESCE(dc.declared_count, 0)         AS declared_count,
  COALESCE(sc.served_count, 0)           AS served_count,
  COALESCE(ga.gap_add_count, 0)          AS gap_add_count,
  COALESCE(gi.gap_idle_count, 0)         AS gap_idle_count,
  COALESCE(ga.gap_add_refused_count, 0)  AS gap_add_refused_count,
  COALESCE(ga.gap_add_zips, '{}')        AS gap_add_zips,
  COALESCE(gi.gap_idle_zips, '{}')       AS gap_idle_zips
FROM ids
JOIN public.clinician_v2 cv ON cv.id = ids.clinician_id
LEFT JOIN dc ON dc.clinician_id = cv.id
LEFT JOIN sc ON sc.clinician_id = cv.id
LEFT JOIN ga ON ga.clinician_id = cv.id
LEFT JOIN gi ON gi.clinician_id = cv.id
ORDER BY cv.name;
$$;

REVOKE ALL ON FUNCTION public.list_clinician_coverage_gaps() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.list_clinician_coverage_gaps() TO authenticated;

COMMENT ON FUNCTION public.list_clinician_coverage_gaps() IS
  'Roster-wide Territory Planner coverage gaps: per clinician, ZIPs served-but-not-declared (gap_add, refused ZIPs netted out) and declared-but-never-served (gap_idle), cutoff-aware, site-exclusion-aware (migration 61), mirroring territory-planner.html rules.';

COMMIT;

NOTIFY pgrst, 'reload schema';
