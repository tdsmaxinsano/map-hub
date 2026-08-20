-- Coverage-gap summary — roster-wide flag for the Territory Planner gaps
-- ======================================================================
-- The Territory Planner computes per-clinician "coverage gaps" client-side:
--   gapAdd  = ZIPs SERVED (completed-service history, cutoff-aware) but NOT
--             declared in TherapyBoss (clinician_zip_coverages)
--   gapIdle = ZIPs declared in TB but never served
-- Roster Review needs this for EVERY clinician at once (a sortable
-- "Coverage Gaps" column + a "Has Gaps" filter), and recomputing it
-- client-side would mean loading ~270K history rows per page view.
-- This RPC computes the same numbers server-side, once per roster load.
--
-- THE PLANNER IS MASTER — each CTE mirrors a territory-planner.html
-- function (named below). Rules deliberately mirrored:
--   * history attribution  = matched_clinician_id first, then a
--     normalized-name fallback ONLY for unmatched link rows (the
--     normalize_clinician_name helper from migration 53)
--   * episode dedupe       = the planner's content-key collapse of
--     duplicate rows across overlapping TB exports (buildSites feed)
--   * Ignore-History-Before cutoff read from clinician_profiles.tags
--     with all FOUR spellings in the planner's JS order (NOTE: RPCs
--     51/53/56/57 read only two, reversed — do NOT "fix" this to match
--     them, the JS reader is the source of truth)
--   * NO history window — the planner loads all years (do not copy
--     migration 53's Jan-1-of-last-year suggest-engine window)
--   * ZIP = TRIM(zip_code), else first 5-digit word in full_address
--   * declared set falls back to clinician_v2.preferred_zips (comma
--     split) only when a clinician has ZERO coverage rows
--   * ⛔ Won't-serve ZIPs (clinician_zip_exclusions) are NETTED OUT of
--     gap_add_count/gap_add_zips (user decision Aug 2026 — a refused
--     ZIP isn't a real "add to TB" gap); they come back separately as
--     gap_add_refused_count so the UI can hint "⛔ n refused". The
--     planner's gap card applies the same netting client-side.
--   * refused-but-DECLARED ZIPs stay inside gap_idle — "declared in TB
--     but they refuse it" is an actionable remove-from-TB signal.
--
-- Known accepted divergences from the planner (rare rows):
--   * name-fallback: the planner's ILIKE pass-2 can attribute a
--     co-treatment row even when the link row matched someone else;
--     this RPC follows the 51/53/56/57 COALESCE precedent instead.
--   * cutoff parsing: only ISO-prefixed (YYYY-MM-DD...) tag values are
--     honored (the JS accepts anything Date-parsable) — same limitation
--     as the existing RPCs.
--   * dedupe survivor: duplicates differing only in referral_date can
--     carry different anchors; survivor order (matched-first, then
--     created_at, id) mirrors the planner's insertion order.
--
-- Read by roster-review.html (safeRpc — an unrun migration degrades to
-- muted "—" cells). Same zero-arg per-clinician-summary shape as
-- list_clinician_visit_summary (migration 17) so the roster's existing
-- dual-key lookup plumbing works unchanged.
--
-- Idempotent — safe to re-run. Run after 59_zip_coverage_revisions.sql.
-- Requires normalize_clinician_name() from 53_suggest_mirror_map.sql.

BEGIN;

-- Return-shape changes require DROP-then-CREATE (42P13).
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
-- ~100 roster names, normalized once (MATERIALIZED so the helper never
-- runs per join probe).
roster_names AS MATERIALIZED (
  SELECT cv.id, normalize_clinician_name(cv.name) AS norm_name
  FROM public.clinician_v2 cv
  WHERE cv.name IS NOT NULL
),
-- History attribution — matched id wins; the name-normalize join runs
-- ONLY over unmatched link rows (src_rank mirrors the planner's
-- "matched rows inserted first" order for the dedupe survivor pick).
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
-- Episode rows + the planner's duplicate-episode collapse (content key)
-- and anchor-date precedence. Dates are TEXT-or-DATE ambiguous — always
-- ::text + regex-guarded LEFT(...,10), never a bare ::date cast.
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
  ORDER BY l.clinician_id, ep.dedupe_key, l.src_rank, r.created_at, r.id
),
-- Ignore-History-Before per clinician — all FOUR tag spellings, JS order.
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
-- Served ZIP episode counts (cutoff-aware). No-anchor rows stay
-- eligible; a NON-ISO anchor under an active cutoff is excluded
-- (matches the JS: NaN >= cutoff is false).
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
-- Declared TB ZIPs (DISTINCT across disciplines) + the preferred_zips
-- fallback for clinicians whose coverage import never ran.
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
-- The gaps themselves.
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
-- Per-clinician rollups. gap_add arrays/counts EXCLUDE refused ZIPs
-- (netting decision above); refused come back as their own count.
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
  'Roster-wide Territory Planner coverage gaps: per clinician, ZIPs served-but-not-declared (gap_add, refused ZIPs netted out) and declared-but-never-served (gap_idle), cutoff-aware, mirroring territory-planner.html rules. Drives the Roster Review Coverage Gaps column.';

COMMIT;

NOTIFY pgrst, 'reload schema';
