-- Disk IO relief: indexes for the completed-services hot paths
-- ============================================================
-- Sep 2026: Supabase emailed a "Disk IO Budget depleting" warning for the
-- project. The heaviest access patterns in the portal all hit
-- therapy_boss_completed_service_import_rows — the biggest table in the DB
-- (multi-year visit history, wide rows) — and none of its query columns
-- were indexed, so Postgres full-scans it from disk:
--
--  1. MAP BOOT (every map open, every user): rows filtered by an OR across
--     4 date columns (the 2-year window) → with no date indexes this is a
--     sequential scan of the whole table. Four single-column btree indexes
--     let the planner BitmapOr them instead.
--  2. MAP BOOT year-availability pass: id + the 4 dates over ALL rows,
--     ordered by created_at → a covering index turns the wide heap scan
--     into an index-only scan.
--  3. Per-profile name fallback + planner name matching:
--     clinician_names_raw ILIKE '%name%' — a leading-wildcard ILIKE can
--     never use a btree; a pg_trgm GIN index makes it an index search.
--     (The roster gap RPC + planner tray RPC use the same predicate.)
--  4. The assignment link table is joined/filtered by service_row_id and
--     matched_clinician_id — Postgres does NOT auto-index FK columns.
--
-- Pure additive DDL — no behavior change anywhere. Index builds take a
-- brief write lock; at this table size that's seconds. Idempotent.

BEGIN;

CREATE EXTENSION IF NOT EXISTS pg_trgm;

-- (1) The 4 date columns behind the map-boot recent-window OR filter
CREATE INDEX IF NOT EXISTS idx_tbcs_rows_last_visit_date
  ON public.therapy_boss_completed_service_import_rows (last_visit_date);
CREATE INDEX IF NOT EXISTS idx_tbcs_rows_ended_date
  ON public.therapy_boss_completed_service_import_rows (ended_date);
CREATE INDEX IF NOT EXISTS idx_tbcs_rows_start_of_episode
  ON public.therapy_boss_completed_service_import_rows (start_of_episode);
CREATE INDEX IF NOT EXISTS idx_tbcs_rows_referral_date
  ON public.therapy_boss_completed_service_import_rows (referral_date);

-- (2) Covering index for the year-availability pass
--     (SELECT id, 4 dates ... ORDER BY created_at → index-only scan)
CREATE INDEX IF NOT EXISTS idx_tbcs_rows_year_cover
  ON public.therapy_boss_completed_service_import_rows (created_at)
  INCLUDE (id, last_visit_date, ended_date, start_of_episode, referral_date);

-- (3) Trigram index for the ILIKE '%name%' clinician-name fallback
CREATE INDEX IF NOT EXISTS idx_tbcs_rows_clinician_names_trgm
  ON public.therapy_boss_completed_service_import_rows
  USING gin (clinician_names_raw gin_trgm_ops);

-- (4) FK-side lookups on the assignment link table
CREATE INDEX IF NOT EXISTS idx_tbcs_clin_service_row_id
  ON public.therapy_boss_completed_service_import_clinicians (service_row_id);
CREATE INDEX IF NOT EXISTS idx_tbcs_clin_matched_clinician_id
  ON public.therapy_boss_completed_service_import_clinicians (matched_clinician_id);

COMMIT;

-- Refresh planner stats so the new indexes get picked up right away.
-- (ANALYZE is transaction-safe, so it can run batched in the SQL editor.)
ANALYZE public.therapy_boss_completed_service_import_rows;
ANALYZE public.therapy_boss_completed_service_import_clinicians;

-- OPTIONAL — must be run BY ITSELF in its own SQL-editor run (VACUUM
-- errors with 25001 when batched with any other statement, because the
-- editor wraps the whole run in one transaction). It freshens the
-- visibility map so the covering index can serve index-only scans
-- immediately; autovacuum does the same on its own soon anyway, so
-- skipping it just delays that benefit slightly.
--
--   VACUUM public.therapy_boss_completed_service_import_rows;
