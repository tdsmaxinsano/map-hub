-- ════════════════════════════════════════════════════════════════════
-- 88 · get_last_import: latest import_log run for one key, WITH notes
--      (requires migration 49)
--
-- Bank Match (Finance → QB Tools) now logs the Chase date range it
-- analyzed in import_log.notes ("analyzed 2026-10-17..2026-11-02 · 54
-- BCBS of 449 rows · <file>"). list_import_log() deliberately omits
-- notes and the Imports hub depends on its shape, so this small RPC
-- returns the latest run for a single key including the notes — used
-- by finance.html's "📅 Last analyzed …" line. Admin/editor, same
-- posture as migration 49. Idempotent.
-- ════════════════════════════════════════════════════════════════════
BEGIN;

DROP FUNCTION IF EXISTS public.get_last_import(TEXT);
CREATE FUNCTION public.get_last_import(p_key TEXT)
RETURNS TABLE (
  label             TEXT,
  row_count         INTEGER,
  notes             TEXT,
  imported_at       TIMESTAMPTZ,
  imported_by_email TEXT
)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM user_roles ur
                 WHERE ur.user_id = auth.uid() AND ur.role IN ('admin','editor')) THEN
    RAISE EXCEPTION 'Only admin or editor may read the import log';
  END IF;
  RETURN QUERY
    SELECT il.label, il.row_count, il.notes, il.imported_at,
           (SELECT u.email FROM auth.users u WHERE u.id = il.imported_by)
      FROM import_log il
     WHERE il.import_key = p_key
     ORDER BY il.imported_at DESC
     LIMIT 1;
END $$;

REVOKE ALL ON FUNCTION public.get_last_import(TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_last_import(TEXT) TO authenticated, service_role;

NOTIFY pgrst, 'reload schema';

COMMIT;
