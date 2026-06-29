-- Import Log — central record of every data import run in the portal.
-- =====================================================================
-- Backs the new admin-only 📥 Imports hub (imports.html), which catalogs
-- every import in the site and shows when each was last run (+ who / how
-- many rows). Each importer across the tools calls `log_import(...)`
-- fire-and-forget on success, so the hub has a real "last run" for
-- everything — not just the handful of imports that already persist a
-- timestamp in their own tables.
--
-- Schema decisions:
-- - One append-only row per import run, keyed by a stable `import_key`
--   (e.g. 'map_clinicians') that the hub's catalog array also uses.
-- - `imported_by` is nullable so the one-shot backfill (run from the SQL
--   editor, where auth.uid() is NULL) can seed historical last-run dates.
-- - Admin-only read (the hub is admin-only); write allowed for admin OR
--   editor, since some imports (Map bulk import, referrals, compliance,
--   roster) are editor-accessible and should still be logged.
--
-- Idempotent — safe to re-run. The backfill only seeds a key that has no
-- row yet, and each source is wrapped so a missing table/column is skipped.
-- Run after: 01_phase1_enable_rls.sql (depends on user_roles).

BEGIN;

-- ── 1. Table ──────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.import_log (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  import_key    TEXT NOT NULL,                 -- stable catalog id, e.g. 'map_clinicians'
  label         TEXT,                          -- human label snapshot
  area          TEXT,                          -- 'Map' | 'Compliance' | 'Finance' | 'Roster' | 'Agencies'
  row_count     INTEGER,                       -- rows imported (NULL if unknown)
  notes         TEXT,
  imported_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  imported_by   UUID REFERENCES auth.users(id) -- nullable (backfill seeds NULL)
);

CREATE INDEX IF NOT EXISTS import_log_key_time_idx
  ON public.import_log (import_key, imported_at DESC);

-- ── 2. RLS ────────────────────────────────────────────────────────
ALTER TABLE public.import_log ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "il_admin_read"  ON public.import_log;
DROP POLICY IF EXISTS "il_write"        ON public.import_log;

-- Read: admin only (matches the admin-only hub).
CREATE POLICY "il_admin_read" ON public.import_log
  FOR SELECT TO authenticated
  USING (EXISTS (SELECT 1 FROM public.user_roles ur
                 WHERE ur.user_id = auth.uid() AND ur.role = 'admin'));

-- Write: admin OR editor (the roles that can actually run imports).
CREATE POLICY "il_write" ON public.import_log
  FOR ALL TO authenticated
  USING      (EXISTS (SELECT 1 FROM public.user_roles ur
                      WHERE ur.user_id = auth.uid() AND ur.role IN ('admin','editor')))
  WITH CHECK (EXISTS (SELECT 1 FROM public.user_roles ur
                      WHERE ur.user_id = auth.uid() AND ur.role IN ('admin','editor')));

-- ── 3. RPC: log_import ────────────────────────────────────────────
-- Append one run row, stamped with auth.uid(). Importers call this
-- fire-and-forget on success; a failure must never block the import.
CREATE OR REPLACE FUNCTION public.log_import(
  p_key       TEXT,
  p_label     TEXT    DEFAULT NULL,
  p_area      TEXT    DEFAULT NULL,
  p_row_count INTEGER DEFAULT NULL,
  p_notes     TEXT    DEFAULT NULL
)
RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  new_id UUID;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM user_roles ur
                 WHERE ur.user_id = auth.uid() AND ur.role IN ('admin','editor')) THEN
    RAISE EXCEPTION 'Only admin or editor may log imports';
  END IF;
  IF p_key IS NULL OR TRIM(p_key) = '' THEN
    RAISE EXCEPTION 'import_key required';
  END IF;

  INSERT INTO import_log (import_key, label, area, row_count, notes, imported_by)
  VALUES (TRIM(p_key), p_label, p_area, p_row_count, p_notes, auth.uid())
  RETURNING id INTO new_id;

  RETURN new_id;
END $$;

REVOKE ALL ON FUNCTION public.log_import(TEXT, TEXT, TEXT, INTEGER, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.log_import(TEXT, TEXT, TEXT, INTEGER, TEXT) TO authenticated;

-- ── 4. RPC: list_import_log ───────────────────────────────────────
-- Latest run per import_key + a total run_count. LEFT-style email
-- lookup via subquery (auth.users.email is VARCHAR → ::TEXT cast, same
-- gotcha as list_patient_check_deposits). Admin-only.
DROP FUNCTION IF EXISTS public.list_import_log();
CREATE OR REPLACE FUNCTION public.list_import_log()
RETURNS TABLE (
  import_key       TEXT,
  label            TEXT,
  area             TEXT,
  last_imported_at TIMESTAMPTZ,
  last_imported_by UUID,
  last_email       TEXT,
  last_row_count   INTEGER,
  run_count        BIGINT
)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM user_roles ur
                 WHERE ur.user_id = auth.uid() AND ur.role = 'admin') THEN
    RAISE EXCEPTION 'Only admin may list the import log';
  END IF;

  RETURN QUERY
    WITH latest AS (
      SELECT DISTINCT ON (l.import_key)
        l.import_key, l.label, l.area, l.imported_at, l.imported_by, l.row_count
      FROM import_log l
      ORDER BY l.import_key, l.imported_at DESC
    ),
    counts AS (
      SELECT l.import_key AS k, COUNT(*) AS rc FROM import_log l GROUP BY l.import_key
    )
    SELECT
      la.import_key::TEXT,
      la.label::TEXT,
      la.area::TEXT,
      la.imported_at,
      la.imported_by,
      (SELECT u.email::TEXT FROM auth.users u WHERE u.id = la.imported_by) AS last_email,
      la.row_count,
      c.rc
    FROM latest la
    JOIN counts c ON c.k = la.import_key;
END $$;

REVOKE ALL ON FUNCTION public.list_import_log() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.list_import_log() TO authenticated;

-- ── 5. One-shot backfill ──────────────────────────────────────────
-- Seed the latest known run from tables that already carry a timestamp,
-- so day-one isn't all "never". Each source is wrapped in its own
-- BEGIN/EXCEPTION so a missing table/column is silently skipped, and
-- each only seeds a key that has no import_log row yet (idempotent).
DO $backfill$
DECLARE
  src RECORD;
BEGIN
  FOR src IN
    SELECT * FROM (VALUES
      ('fin_vdr',         'VDR Runner (Create bills)', 'Finance',    'vdr_runs',                                  'ran_at'),
      ('fin_payroll',     'Clinician Payroll Audit',   'Finance',    'clinician_payroll_runs',                    'imported_at'),
      ('agency_tb',       'TB Price List',             'Agencies',   'home_health_agency_rate_history',           'imported_at'),
      ('comp_evaluation', 'Evaluation (2-file)',       'Compliance', 'evaluation_compliance_items',               'imported_at'),
      ('comp_frequency',  'Frequency (Create bills)',  'Compliance', 'compliance_imports',                        'imported_at'),
      ('roster_visits',   'Bulk visits',               'Roster',     'clinician_visit_period_metrics',            'imported_at'),
      ('map_zip',         'ZIP coverage',              'Map',        'therapy_boss_zip_coverage_import_batches',  'imported_at'),
      ('map_referrals',   'Referrals (TB staging)',    'Map',        'therapy_boss_referral_import_batches',      'imported_at')
    ) AS t(key, label, area, tbl, ts_col)
  LOOP
    BEGIN
      IF to_regclass('public.' || src.tbl) IS NOT NULL
         AND NOT EXISTS (SELECT 1 FROM import_log WHERE import_key = src.key) THEN
        EXECUTE format(
          'INSERT INTO public.import_log (import_key, label, area, imported_at, imported_by, notes)
             SELECT %L, %L, %L, MAX(%I), NULL, %L
             FROM public.%I
             HAVING MAX(%I) IS NOT NULL',
          src.key, src.label, src.area, src.ts_col, 'backfilled from ' || src.tbl,
          src.tbl, src.ts_col
        );
      END IF;
    EXCEPTION WHEN OTHERS THEN
      -- table exists but column differs / not accessible → skip this source
      NULL;
    END;
  END LOOP;
END $backfill$;

COMMIT;

NOTIFY pgrst, 'reload schema';
