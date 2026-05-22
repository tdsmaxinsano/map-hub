-- Evaluation Compliance — TB Active Services driven tracker
-- =====================================================================
-- Converts the user's hand-maintained Evaluation Compliance spreadsheet
-- into a portal-resident tracker. Source of truth = TB's "Active Services"
-- report (browser-side XLSX import). Each row is anchored by
-- (patient_id, referral_id) which come straight from TB and are
-- non-editable in the UI.
--
-- Schema:
--   * evaluation_compliance_items — one row per (patient_id, referral_id)
--   * list_evaluation_compliance() — SECURITY DEFINER read RPC
--   * upsert_evaluation_items(rows, batch_id) — bulk import RPC
--     (preserves user-edited columns; only refreshes TB-sourced ones)
--   * update_evaluation_item(id, ...) — targeted single-row patch
--
-- RLS:
--   * SELECT — any authenticated user
--   * INSERT/UPDATE/DELETE — admin + editor only (matches Frequency
--     Compliance gating; readonly users see the queue but can't change it)
--
-- Idempotent — safe to re-run.

BEGIN;

-- ── Table ─────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.evaluation_compliance_items (
  id                    UUID PRIMARY KEY DEFAULT gen_random_uuid(),

  -- TB anchors (non-editable in UI, re-set by every import)
  patient_id            TEXT NOT NULL,
  referral_id           TEXT NOT NULL,

  -- TB-sourced (refreshed by every import, not user-editable)
  patient_name          TEXT NOT NULL,
  episode_start_date    DATE,
  episode_end_date      DATE,
  service               TEXT,                 -- "PT" | "OT" | "ST" | etc.
  home_health_agency    TEXT,
  tb_clinician_name     TEXT,                 -- raw from TB; resolved to clinician_id below

  -- Portal-managed (user-editable)
  clinician_id          UUID REFERENCES public.clinician_v2(id) ON DELETE SET NULL,
  category              TEXT NOT NULL DEFAULT 'Active',
                        -- "Active" | "Issues" | "Hold/Hospital" | "Re-Evaluation"
                        -- "No Sched" | "Scheduled-Late Eval" | "To Sync" | "Completed"
                        -- "Assigned"
  sync_status           TEXT NOT NULL DEFAULT 'no_evaluation',
                        -- "synced" (green) | "eval_done_not_synced" (yellow)
                        -- "no_evaluation" (white) | "cancelled" (gray)
  status_notes          TEXT,                 -- free-form e.g. "PTE 5/14 1x1,2x2 approved"

  -- Import provenance + audit
  imported_at           TIMESTAMPTZ NOT NULL DEFAULT now(),
  import_batch_id       UUID,                 -- groups all rows from one import
  last_edited_at        TIMESTAMPTZ,
  last_edited_by        UUID,
  is_archived           BOOLEAN NOT NULL DEFAULT false,

  UNIQUE (patient_id, referral_id)
);

CREATE INDEX IF NOT EXISTS idx_eval_category    ON public.evaluation_compliance_items (category)    WHERE NOT is_archived;
CREATE INDEX IF NOT EXISTS idx_eval_sync_status ON public.evaluation_compliance_items (sync_status) WHERE NOT is_archived;
CREATE INDEX IF NOT EXISTS idx_eval_clinician   ON public.evaluation_compliance_items (clinician_id) WHERE NOT is_archived;

-- ── RLS ────────────────────────────────────────────────────────────
ALTER TABLE public.evaluation_compliance_items ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "eval_select_auth"           ON public.evaluation_compliance_items;
DROP POLICY IF EXISTS "eval_write_editor_admin"    ON public.evaluation_compliance_items;

CREATE POLICY "eval_select_auth" ON public.evaluation_compliance_items
  FOR SELECT TO authenticated USING (true);

CREATE POLICY "eval_write_editor_admin" ON public.evaluation_compliance_items
  FOR ALL TO authenticated
  USING      (EXISTS (SELECT 1 FROM public.user_roles ur
                      WHERE ur.user_id = auth.uid() AND ur.role IN ('admin','editor')))
  WITH CHECK (EXISTS (SELECT 1 FROM public.user_roles ur
                      WHERE ur.user_id = auth.uid() AND ur.role IN ('admin','editor')));

-- ── RPC: list ─────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.list_evaluation_compliance()
RETURNS SETOF public.evaluation_compliance_items
LANGUAGE sql SECURITY DEFINER SET search_path = public AS $$
  SELECT * FROM public.evaluation_compliance_items
  WHERE NOT is_archived
  ORDER BY category, patient_name;
$$;

-- ── RPC: bulk upsert from an import ───────────────────────────────
-- Accepts a JSONB array of TB-sourced rows + a batch_id. Upserts on
-- (patient_id, referral_id) — preserves user-edited columns on conflict.
CREATE OR REPLACE FUNCTION public.upsert_evaluation_items(rows JSONB, batch_id UUID)
RETURNS INTEGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE n INT;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM user_roles ur
                 WHERE ur.user_id = auth.uid() AND ur.role IN ('admin','editor')) THEN
    RAISE EXCEPTION 'Only admin/editor may import evaluation items';
  END IF;

  WITH src AS (
    SELECT x.*, row_number() OVER () AS rn
    FROM jsonb_to_recordset(rows) AS x(
      patient_id          TEXT, referral_id        TEXT,
      patient_name        TEXT, episode_start_date DATE, episode_end_date DATE,
      service             TEXT, home_health_agency TEXT, tb_clinician_name TEXT
    )
  ),
  -- Defensive dedupe: if the same (patient_id, referral_id) appears more than
  -- once in the inbound payload, ON CONFLICT … DO UPDATE would otherwise raise
  -- "cannot affect row a second time". DISTINCT ON keeps the last occurrence
  -- (uses ROW_NUMBER over input order as the tiebreaker — jsonb_to_recordset
  -- output has no ctid since it's an in-memory rowset, not a real table).
  src_dedup AS (
    SELECT DISTINCT ON (patient_id, referral_id)
           patient_id, referral_id, patient_name, episode_start_date, episode_end_date,
           service, home_health_agency, tb_clinician_name
    FROM src
    WHERE patient_id IS NOT NULL AND referral_id IS NOT NULL
      AND TRIM(patient_id) <> '' AND TRIM(referral_id) <> ''
    ORDER BY patient_id, referral_id, rn DESC
  ),
  ins AS (
    INSERT INTO evaluation_compliance_items
      (patient_id, referral_id, patient_name, episode_start_date, episode_end_date,
       service, home_health_agency, tb_clinician_name, imported_at, import_batch_id)
    SELECT patient_id, referral_id, patient_name, episode_start_date, episode_end_date,
           service, home_health_agency, tb_clinician_name, now(), batch_id
    FROM src_dedup
    ON CONFLICT (patient_id, referral_id) DO UPDATE
      SET patient_name        = EXCLUDED.patient_name,
          episode_start_date  = EXCLUDED.episode_start_date,
          episode_end_date    = EXCLUDED.episode_end_date,
          service             = EXCLUDED.service,
          home_health_agency  = EXCLUDED.home_health_agency,
          tb_clinician_name   = EXCLUDED.tb_clinician_name,
          imported_at         = now(),
          import_batch_id     = batch_id
    RETURNING 1
  )
  SELECT count(*) INTO n FROM ins;

  RETURN n;
END $$;

-- ── RPC: targeted single-row patch ────────────────────────────────
-- Used by inline editors in the Evaluation view. Only touches the
-- portal-managed columns (TB-sourced columns are immutable by users).
CREATE OR REPLACE FUNCTION public.update_evaluation_item(
  item_id          UUID,
  new_category     TEXT DEFAULT NULL,
  new_sync_status  TEXT DEFAULT NULL,
  new_status_notes TEXT DEFAULT NULL,
  new_clinician_id UUID DEFAULT NULL
) RETURNS public.evaluation_compliance_items
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE r public.evaluation_compliance_items;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM user_roles ur
                 WHERE ur.user_id = auth.uid() AND ur.role IN ('admin','editor')) THEN
    RAISE EXCEPTION 'Only admin/editor may update evaluation items';
  END IF;

  UPDATE evaluation_compliance_items SET
    category       = COALESCE(new_category,     category),
    sync_status    = COALESCE(new_sync_status,  sync_status),
    status_notes   = COALESCE(new_status_notes, status_notes),
    clinician_id   = COALESCE(new_clinician_id, clinician_id),
    last_edited_at = now(),
    last_edited_by = auth.uid()
  WHERE id = item_id
  RETURNING * INTO r;
  RETURN r;
END $$;

-- ── RPC: clear all evaluation_compliance_items ────────────────────
-- Admin-only nuke for the queue. Returns the row count that was deleted
-- so the UI can confirm. Use case: starting fresh after a bad import,
-- or after the spreadsheet-era data has been superseded.
CREATE OR REPLACE FUNCTION public.clear_evaluation_compliance()
RETURNS INTEGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE n INT;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM user_roles ur
                 WHERE ur.user_id = auth.uid() AND ur.role = 'admin') THEN
    RAISE EXCEPTION 'Only admin may clear evaluation compliance items';
  END IF;
  -- Supabase platform requires every DELETE to have a WHERE clause; use a
  -- trivially-true predicate to wipe every row.
  DELETE FROM evaluation_compliance_items WHERE id IS NOT NULL;
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END $$;

REVOKE ALL ON FUNCTION public.list_evaluation_compliance()                                FROM PUBLIC;
REVOKE ALL ON FUNCTION public.upsert_evaluation_items(JSONB, UUID)                        FROM PUBLIC;
REVOKE ALL ON FUNCTION public.update_evaluation_item(UUID, TEXT, TEXT, TEXT, UUID)        FROM PUBLIC;
REVOKE ALL ON FUNCTION public.clear_evaluation_compliance()                               FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.list_evaluation_compliance()                              TO authenticated;
GRANT EXECUTE ON FUNCTION public.upsert_evaluation_items(JSONB, UUID)                      TO authenticated;
GRANT EXECUTE ON FUNCTION public.update_evaluation_item(UUID, TEXT, TEXT, TEXT, UUID)      TO authenticated;
GRANT EXECUTE ON FUNCTION public.clear_evaluation_compliance()                              TO authenticated;

COMMIT;

-- Force PostgREST to reload its schema cache so the new function is callable
-- from the API immediately, instead of waiting for the periodic refresh.
-- Without this, `db.rpc("clear_evaluation_compliance")` returns
-- "Could not find the function ... in the schema" for ~10 minutes after deploy.
NOTIFY pgrst, 'reload schema';
