-- Clinician address-change notifications
-- =====================================================================
-- When the Map's Bulk Import detects a clinician address change in TB
-- (in either the Sync Update mode or the Additions Only mode's
-- opportunistic address backfill — see clinician-map.html
-- uploadClinicianMasterImportToSupabase), three notifications now fire:
--
--   1. EMAIL — the existing send-import-report Edge Function (no change)
--   2. HOME ALERT — a 'address_changed' row on the News & Alerts board
--      driven by list_address_change_alerts() (7-day visibility window;
--      can be dismissed with ✕ which stamps acknowledged_at)
--   3. KANBAN TASK — auto-created on the new "Roster Verification"
--      board's "New" column so HR can verify the new address
--
-- This migration owns:
--   • clinician_address_changes table  (narrow log, NOT a full audit framework)
--   • Roster Verification board + 3 columns (seed via slug UNIQUE)
--   • record_clinician_address_change(...)  — atomic write of log row + task
--   • list_address_change_alerts()           — feeds the News & Alerts board
--   • acknowledge_address_change(id)         — drives the ✕ dismiss
--
-- RLS — SELECT for authenticated; writes routed through SECURITY DEFINER
-- RPCs (admin-only via inline auth check).
-- Idempotent — safe to re-run.

BEGIN;

-- ── 1. Log table ──────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.clinician_address_changes (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  clinician_id    UUID NOT NULL REFERENCES public.clinician_v2(id) ON DELETE CASCADE,
  old_address     TEXT,
  new_address     TEXT NOT NULL,
  source          TEXT NOT NULL CHECK (source IN (
                    'bulk_import_additions_only',
                    'bulk_import_sync_update',
                    'manual'
                  )),
  changed_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  changed_by      UUID REFERENCES auth.users(id),
  task_id         UUID REFERENCES public.tasks(id) ON DELETE SET NULL,
  acknowledged_at TIMESTAMPTZ,
  acknowledged_by UUID REFERENCES auth.users(id)
);
CREATE INDEX IF NOT EXISTS cac_changed_at_idx ON public.clinician_address_changes (changed_at DESC);
CREATE INDEX IF NOT EXISTS cac_clinician_idx  ON public.clinician_address_changes (clinician_id);

-- ── 2. RLS — read for authenticated; writes only via RPCs ─────────
ALTER TABLE public.clinician_address_changes ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "cac_select_authenticated" ON public.clinician_address_changes;
CREATE POLICY "cac_select_authenticated" ON public.clinician_address_changes
  FOR SELECT TO authenticated USING (true);
-- No INSERT/UPDATE policy — all writes go through SECURITY DEFINER RPCs.

-- ── 3. Roster Verification kanban board seed ──────────────────────
-- Mirrors the seed pattern from migration 02 (insert by slug, columns
-- by name, both idempotent). HR uses this board to verify each address
-- change against the clinician's TB record before clearing the task.
INSERT INTO public.boards (name, slug, icon, position, is_default)
VALUES ('Roster Verification', 'roster-verification', '📍', 5, false)
ON CONFLICT (slug) DO NOTHING;

INSERT INTO public.board_columns (board_id, name, position, is_done)
SELECT b.id, c.name, c.position, c.is_done
FROM public.boards b
CROSS JOIN (VALUES
  ('New',           0, false),
  ('Verified',      1, false),
  ('Updated in TB', 2, true)
) AS c(name, position, is_done)
WHERE b.slug = 'roster-verification'
  AND NOT EXISTS (
    SELECT 1 FROM public.board_columns bc
    WHERE bc.board_id = b.id AND bc.name = c.name
  );

-- ── 4. RPC: record_clinician_address_change ───────────────────────
-- Atomic: inserts the log row + inserts a kanban task on the Roster
-- Verification board's "New" column + back-links the task_id to the
-- log row. Called from the client right after each address backfill
-- write succeeds (both modes).
--
-- Returns the new change row ID + the linked task ID so the client can
-- show "✓ task created" feedback if useful (not required).
CREATE OR REPLACE FUNCTION public.record_clinician_address_change(
  p_clinician_id UUID,
  p_old          TEXT,
  p_new          TEXT,
  p_source       TEXT
)
RETURNS TABLE(change_id UUID, task_id UUID)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_board_id   UUID;
  v_column_id  UUID;
  v_task_id    UUID;
  v_change_id  UUID;
  v_clin_name  TEXT;
BEGIN
  -- Admin-only (matches Finance / Bulk-import posture)
  IF NOT EXISTS (SELECT 1 FROM user_roles
                 WHERE user_id = auth.uid() AND role = 'admin') THEN
    RAISE EXCEPTION 'Only admin may record clinician address changes';
  END IF;
  IF p_clinician_id IS NULL OR p_new IS NULL OR TRIM(p_new) = '' THEN
    RAISE EXCEPTION 'clinician_id and new address are required';
  END IF;

  -- Resolve the Roster Verification "New" column. If the seed didn't
  -- run (e.g., the board was renamed), skip task creation gracefully.
  SELECT id INTO v_board_id FROM boards WHERE slug = 'roster-verification' LIMIT 1;
  IF v_board_id IS NOT NULL THEN
    SELECT id INTO v_column_id
    FROM board_columns
    WHERE board_id = v_board_id AND name = 'New'
    LIMIT 1;
  END IF;

  -- Look up the clinician name for the task title + description
  SELECT name INTO v_clin_name FROM clinician_v2 WHERE id = p_clinician_id;

  -- Insert the kanban task FIRST so we have a task_id to store on the log
  IF v_board_id IS NOT NULL AND v_column_id IS NOT NULL THEN
    INSERT INTO tasks (
      title, description,
      board_id, column_id,
      linked_entity_type, linked_entity_id, linked_entity_label,
      created_by
    )
    VALUES (
      'Verify new address — ' || COALESCE(v_clin_name, 'clinician'),
      '📍 Address change detected from TB bulk import.' || E'\n\n' ||
      '**Old:** ' || COALESCE(NULLIF(TRIM(p_old), ''), '—') || E'\n' ||
      '**New:** ' || TRIM(p_new) || E'\n\n' ||
      '_Move this card to "Verified" once you''ve confirmed the new address against TB, then "Updated in TB" once any downstream systems (Strata, payroll, etc.) are synced. The card auto-archives 7 days after the "Updated in TB" column._',
      v_board_id, v_column_id,
      'clinician', p_clinician_id, COALESCE(v_clin_name, ''),
      auth.uid()
    )
    RETURNING id INTO v_task_id;
  END IF;

  -- Insert the log row with the back-link
  INSERT INTO clinician_address_changes (
    clinician_id, old_address, new_address, source, changed_by, task_id
  )
  VALUES (
    p_clinician_id,
    NULLIF(TRIM(COALESCE(p_old, '')), ''),
    TRIM(p_new),
    p_source,
    auth.uid(),
    v_task_id
  )
  RETURNING id INTO v_change_id;

  change_id := v_change_id;
  task_id := v_task_id;
  RETURN NEXT;
END $$;

REVOKE ALL ON FUNCTION public.record_clinician_address_change(UUID, TEXT, TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.record_clinician_address_change(UUID, TEXT, TEXT, TEXT) TO authenticated;

-- ── 5. RPC: list_address_change_alerts ────────────────────────────
-- Returns address-change rows from the last 7 days that:
--   (a) have NOT been acknowledged, AND
--   (b) whose linked kanban task is still open (column.is_done = false
--       OR no task link), AND
--   (c) the task isn't archived.
-- Same row shape as list_pause_alerts so the Home page renderer can
-- fold the new alert_type into its existing pipeline.
CREATE OR REPLACE FUNCTION public.list_address_change_alerts()
RETURNS TABLE(
  alert_type      TEXT,
  change_id       UUID,
  clinician_id    UUID,
  clinician_name  TEXT,
  discipline      TEXT,
  old_address     TEXT,
  new_address     TEXT,
  source          TEXT,
  changed_at      TIMESTAMPTZ,
  task_id         UUID,
  days_offset     INTEGER
)
LANGUAGE sql SECURITY DEFINER SET search_path = public AS $$
  SELECT
    'address_changed'::TEXT                                  AS alert_type,
    cac.id                                                   AS change_id,
    cac.clinician_id,
    v.name                                                   AS clinician_name,
    v.discipline                                             AS discipline,
    cac.old_address,
    cac.new_address,
    cac.source,
    cac.changed_at,
    cac.task_id,
    -((CURRENT_DATE - cac.changed_at::date))::INTEGER        AS days_offset
  FROM public.clinician_address_changes cac
  JOIN public.clinician_v2 v ON v.id = cac.clinician_id
  LEFT JOIN public.tasks t ON t.id = cac.task_id
  LEFT JOIN public.board_columns bc ON bc.id = t.column_id
  WHERE cac.acknowledged_at IS NULL
    AND cac.changed_at > now() - INTERVAL '7 days'
    -- If a task exists, it must still be open. If no task, the row
    -- shows until acknowledged or until the 7-day window expires.
    AND (t.id IS NULL OR (t.is_archived = false AND COALESCE(bc.is_done, false) = false))
  ORDER BY cac.changed_at DESC;
$$;

REVOKE ALL ON FUNCTION public.list_address_change_alerts() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.list_address_change_alerts() TO authenticated;

-- ── 6. RPC: acknowledge_address_change ────────────────────────────
-- Stamps acknowledged_at + acknowledged_by. Drives the ✕ dismiss
-- button on each address_changed alert card. Idempotent — re-acks
-- update the stamp (last writer wins).
CREATE OR REPLACE FUNCTION public.acknowledge_address_change(p_change_id UUID)
RETURNS BOOLEAN
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM user_roles
                 WHERE user_id = auth.uid() AND role IN ('admin', 'editor')) THEN
    RAISE EXCEPTION 'Only admin or editor may acknowledge alerts';
  END IF;
  UPDATE clinician_address_changes
    SET acknowledged_at = now(),
        acknowledged_by = auth.uid()
  WHERE id = p_change_id;
  RETURN FOUND;
END $$;

REVOKE ALL ON FUNCTION public.acknowledge_address_change(UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.acknowledge_address_change(UUID) TO authenticated;

COMMIT;

NOTIFY pgrst, 'reload schema';
