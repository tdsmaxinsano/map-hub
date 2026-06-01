-- Evaluation Compliance — "Proposed Eval" employee planning + drift tracking
-- =====================================================================
-- The existing "Eval Sched" column shows whatever the TB Scheduled
-- Appointments import last pulled in — read-only. Employees who want to
-- plan an eval BEFORE creating it in TB had nowhere to capture that
-- intent. This migration adds a sibling "Proposed Eval" data slot that
-- the employee enters, plus a separate audit-trail table that logs
-- every transition (proposed → confirmed-on-import-match, or rescheduled
-- by TB → drift → acknowledged).
--
-- Match rule: date only. If proposed_eval_date == next_eval_date (from
-- migration 15's schedule enrichment), the row reads as "confirmed".
-- Clinician mismatch doesn't break the match.
--
-- All confirmation / drift-ack history rows are written on EXPLICIT
-- employee click — not auto-emitted by the import — so the audit trail
-- stays signal-only.
--
-- Idempotent — safe to re-run.

BEGIN;

-- ─── 1. Columns on the item row ───────────────────────────────────────
ALTER TABLE public.evaluation_compliance_items
  ADD COLUMN IF NOT EXISTS proposed_eval_date      DATE,
  ADD COLUMN IF NOT EXISTS proposed_eval_clinician TEXT,
  ADD COLUMN IF NOT EXISTS proposed_eval_note      TEXT,
  ADD COLUMN IF NOT EXISTS proposed_eval_set_at    TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS proposed_eval_set_by    UUID,
  ADD COLUMN IF NOT EXISTS last_acknowledged_at    TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS last_acknowledged_by    UUID;

-- ─── 2. Audit-trail table ────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.evaluation_proposed_history (
  id        UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  item_id   UUID NOT NULL REFERENCES public.evaluation_compliance_items(id) ON DELETE CASCADE,
  action    TEXT NOT NULL CHECK (action IN
             ('proposed','updated','confirmed','drift_acknowledged','cleared')),
  from_date DATE,
  to_date   DATE,
  actor_id  UUID NOT NULL DEFAULT auth.uid(),
  at        TIMESTAMPTZ NOT NULL DEFAULT now(),
  notes     TEXT
);
CREATE INDEX IF NOT EXISTS idx_eph_item_at ON public.evaluation_proposed_history (item_id, at DESC);

ALTER TABLE public.evaluation_proposed_history ENABLE ROW LEVEL SECURITY;

-- SELECT — any authenticated user (read-only audit)
DROP POLICY IF EXISTS "eph_select_auth" ON public.evaluation_proposed_history;
CREATE POLICY "eph_select_auth" ON public.evaluation_proposed_history
  FOR SELECT TO authenticated USING (true);

-- Direct writes blocked — all inserts go through the SECURITY DEFINER RPCs below.
DROP POLICY IF EXISTS "eph_no_direct_write" ON public.evaluation_proposed_history;
CREATE POLICY "eph_no_direct_write" ON public.evaluation_proposed_history
  FOR ALL TO authenticated USING (false) WITH CHECK (false);

-- ─── 3. RPC: set_proposed_eval ───────────────────────────────────────
-- Writes the proposed_* columns + appends a 'proposed' (first time) or
-- 'updated' (subsequent) history row. Admin + editor only.
CREATE OR REPLACE FUNCTION public.set_proposed_eval(
  p_item_id      UUID,
  p_date         DATE,
  p_clinician    TEXT,
  p_note         TEXT
)
RETURNS public.evaluation_compliance_items
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  r_old public.evaluation_compliance_items;
  r_new public.evaluation_compliance_items;
  v_action TEXT;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM user_roles
                 WHERE user_id = auth.uid() AND role IN ('admin','editor')) THEN
    RAISE EXCEPTION 'Only admin/editor may set proposed eval';
  END IF;

  SELECT * INTO r_old FROM evaluation_compliance_items WHERE id = p_item_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Item not found';
  END IF;

  v_action := CASE WHEN r_old.proposed_eval_date IS NULL THEN 'proposed' ELSE 'updated' END;

  UPDATE evaluation_compliance_items SET
    proposed_eval_date      = p_date,
    proposed_eval_clinician = NULLIF(BTRIM(COALESCE(p_clinician, '')), ''),
    proposed_eval_note      = NULLIF(BTRIM(COALESCE(p_note,      '')), ''),
    proposed_eval_set_at    = now(),
    proposed_eval_set_by    = auth.uid(),
    -- A new proposal invalidates any prior acknowledgement.
    last_acknowledged_at    = NULL,
    last_acknowledged_by    = NULL,
    last_edited_at          = now(),
    last_edited_by          = auth.uid()
  WHERE id = p_item_id
  RETURNING * INTO r_new;

  INSERT INTO evaluation_proposed_history (item_id, action, from_date, to_date, notes)
  VALUES (p_item_id, v_action, r_old.proposed_eval_date, p_date,
          NULLIF(BTRIM(COALESCE(p_note,'')),''));

  RETURN r_new;
END $$;

-- ─── 4. RPC: acknowledge_proposed_eval ───────────────────────────────
-- Stamps last_acknowledged_* + writes a 'confirmed' or 'drift_acknowledged'
-- history row. p_action MUST be one of those two values.
CREATE OR REPLACE FUNCTION public.acknowledge_proposed_eval(
  p_item_id UUID,
  p_action  TEXT
)
RETURNS public.evaluation_compliance_items
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  r public.evaluation_compliance_items;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM user_roles
                 WHERE user_id = auth.uid() AND role IN ('admin','editor')) THEN
    RAISE EXCEPTION 'Only admin/editor may acknowledge';
  END IF;
  IF p_action NOT IN ('confirmed','drift_acknowledged') THEN
    RAISE EXCEPTION 'Invalid action: %', p_action;
  END IF;

  UPDATE evaluation_compliance_items SET
    last_acknowledged_at = now(),
    last_acknowledged_by = auth.uid(),
    last_edited_at       = now(),
    last_edited_by       = auth.uid()
  WHERE id = p_item_id
  RETURNING * INTO r;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Item not found';
  END IF;

  -- to_date captures what was acked (either the matched next_eval_date or
  -- the drifted-to TB date — same column either way for traceability).
  INSERT INTO evaluation_proposed_history (item_id, action, from_date, to_date)
  VALUES (p_item_id, p_action, r.proposed_eval_date, r.next_eval_date);

  RETURN r;
END $$;

-- ─── 5. RPC: clear_proposed_eval ─────────────────────────────────────
CREATE OR REPLACE FUNCTION public.clear_proposed_eval(p_item_id UUID)
RETURNS public.evaluation_compliance_items
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  r_old public.evaluation_compliance_items;
  r_new public.evaluation_compliance_items;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM user_roles
                 WHERE user_id = auth.uid() AND role IN ('admin','editor')) THEN
    RAISE EXCEPTION 'Only admin/editor may clear proposed eval';
  END IF;

  SELECT * INTO r_old FROM evaluation_compliance_items WHERE id = p_item_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Item not found';
  END IF;

  UPDATE evaluation_compliance_items SET
    proposed_eval_date      = NULL,
    proposed_eval_clinician = NULL,
    proposed_eval_note      = NULL,
    proposed_eval_set_at    = NULL,
    proposed_eval_set_by    = NULL,
    last_acknowledged_at    = NULL,
    last_acknowledged_by    = NULL,
    last_edited_at          = now(),
    last_edited_by          = auth.uid()
  WHERE id = p_item_id
  RETURNING * INTO r_new;

  INSERT INTO evaluation_proposed_history (item_id, action, from_date, to_date)
  VALUES (p_item_id, 'cleared', r_old.proposed_eval_date, NULL);

  RETURN r_new;
END $$;

-- ─── 6. RPC: list_proposed_history ───────────────────────────────────
CREATE OR REPLACE FUNCTION public.list_proposed_history(p_item_id UUID)
RETURNS SETOF public.evaluation_proposed_history
LANGUAGE sql SECURITY DEFINER SET search_path = public AS $$
  SELECT * FROM evaluation_proposed_history
   WHERE item_id = p_item_id
   ORDER BY at DESC
   LIMIT 50;
$$;

REVOKE ALL ON FUNCTION public.set_proposed_eval(UUID, DATE, TEXT, TEXT)         FROM PUBLIC;
REVOKE ALL ON FUNCTION public.acknowledge_proposed_eval(UUID, TEXT)             FROM PUBLIC;
REVOKE ALL ON FUNCTION public.clear_proposed_eval(UUID)                         FROM PUBLIC;
REVOKE ALL ON FUNCTION public.list_proposed_history(UUID)                       FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.set_proposed_eval(UUID, DATE, TEXT, TEXT)      TO authenticated;
GRANT EXECUTE ON FUNCTION public.acknowledge_proposed_eval(UUID, TEXT)          TO authenticated;
GRANT EXECUTE ON FUNCTION public.clear_proposed_eval(UUID)                      TO authenticated;
GRANT EXECUTE ON FUNCTION public.list_proposed_history(UUID)                    TO authenticated;

COMMIT;

NOTIFY pgrst, 'reload schema';
