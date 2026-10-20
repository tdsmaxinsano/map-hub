-- ════════════════════════════════════════════════════════════════════
-- 84 · Agency merges become PERMANENT + imports become move-aware
--      (requires migration 83)
--
-- Problem: agency ids are address-derived slugs, so (a) a 🔀-merged
-- duplicate could reappear if an import file still carries the old
-- address, and (b) every future address change would mint a fresh
-- duplicate to merge again.
--
-- This migration adds the memory half: agency_merge_aliases records
-- every merge (loser id → survivor id), and merge_agencies now writes
-- it (and re-chains older aliases that pointed at the loser). The map's
-- HH Agencies import reads this table to skip resurrected duplicates,
-- and matches moved agencies by name to update them in place (client
-- change, same PR). Idempotent.
-- ════════════════════════════════════════════════════════════════════
BEGIN;

CREATE TABLE IF NOT EXISTS public.agency_merge_aliases (
  loser_id    TEXT PRIMARY KEY,          -- the deleted duplicate's old id
  survivor_id TEXT NOT NULL REFERENCES public.home_health_agencies(id) ON DELETE CASCADE,
  merged_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
  merged_by   UUID
);

ALTER TABLE public.agency_merge_aliases ENABLE ROW LEVEL SECURITY;

-- Read: anyone signed in (the import runs as admin, but the map shell
-- loads for all roles; the table holds no sensitive data — just id
-- redirects). Writes happen only inside the SECURITY DEFINER merge RPC.
DROP POLICY IF EXISTS "ama_read" ON public.agency_merge_aliases;
CREATE POLICY "ama_read" ON public.agency_merge_aliases
  FOR SELECT TO authenticated USING (true);

-- ── merge_agencies: same behavior as migration 83 + alias bookkeeping ─
CREATE OR REPLACE FUNCTION public.merge_agencies(
  p_loser_id    TEXT,   -- the duplicate to remove
  p_survivor_id TEXT    -- the row that stays (the current address)
)
RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  l home_health_agency_contracts%ROWTYPE;
  s home_health_agency_contracts%ROWTYPE;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM user_roles ur
                 WHERE ur.user_id = auth.uid() AND ur.role = 'admin') THEN
    RAISE EXCEPTION 'Only admin may merge agencies';
  END IF;
  IF p_loser_id IS NULL OR p_survivor_id IS NULL OR p_loser_id = p_survivor_id THEN
    RAISE EXCEPTION 'Pick two different agencies';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM home_health_agencies WHERE id = p_loser_id) THEN
    RAISE EXCEPTION 'Agency % not found', p_loser_id;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM home_health_agencies WHERE id = p_survivor_id) THEN
    RAISE EXCEPTION 'Agency % not found', p_survivor_id;
  END IF;

  -- Rate history: move, survivor wins (bucket, effective_date) collisions.
  INSERT INTO home_health_agency_rate_history
    (agency_id, bucket, tb_type_code, episode_type, bill_rate,
     effective_date, per_hour, source, imported_at, imported_by)
  SELECT p_survivor_id, h.bucket, h.tb_type_code, h.episode_type, h.bill_rate,
         h.effective_date, h.per_hour, h.source, h.imported_at, h.imported_by
    FROM home_health_agency_rate_history h
   WHERE h.agency_id = p_loser_id
  ON CONFLICT (agency_id, bucket, effective_date) DO NOTHING;
  DELETE FROM home_health_agency_rate_history WHERE agency_id = p_loser_id;

  -- Contract: move it over, or coalesce-fill the survivor's.
  SELECT * INTO l FROM home_health_agency_contracts WHERE agency_id = p_loser_id;
  SELECT * INTO s FROM home_health_agency_contracts WHERE agency_id = p_survivor_id;

  IF l.id IS NOT NULL AND s.id IS NULL THEN
    UPDATE home_health_agency_contracts
       SET agency_id = p_survivor_id, updated_at = NOW(), updated_by = auth.uid()
     WHERE agency_id = p_loser_id;
  ELSIF l.id IS NOT NULL AND s.id IS NOT NULL THEN
    UPDATE home_health_agency_contracts SET
      rate_ot_eval         = COALESCE(s.rate_ot_eval,         l.rate_ot_eval),
      rate_ot_assistant    = COALESCE(s.rate_ot_assistant,    l.rate_ot_assistant),
      rate_pt_eval         = COALESCE(s.rate_pt_eval,         l.rate_pt_eval),
      rate_pt_assistant    = COALESCE(s.rate_pt_assistant,    l.rate_pt_assistant),
      rate_st_eval         = COALESCE(s.rate_st_eval,         l.rate_st_eval),
      rate_st_other        = COALESCE(s.rate_st_other,        l.rate_st_other),
      rating_payment       = COALESCE(s.rating_payment,       l.rating_payment),
      rating_communication = COALESCE(s.rating_communication, l.rating_communication),
      contract_location    = COALESCE(s.contract_location,    l.contract_location),
      is_active            = COALESCE(s.is_active,            l.is_active),
      contract_start_year  = COALESCE(s.contract_start_year,  l.contract_start_year),
      preferred_payment_method = COALESCE(s.preferred_payment_method, l.preferred_payment_method),
      sent_via             = COALESCE(s.sent_via,             l.sent_via),
      collections_contact  = COALESCE(s.collections_contact,  l.collections_contact),
      notes = CASE
        WHEN s.notes IS NULL THEN l.notes
        WHEN l.notes IS NULL OR l.notes = s.notes THEN s.notes
        ELSE s.notes || ' | ' || l.notes
      END,
      engagement_status  = CASE WHEN COALESCE(s.engagement_status,'none') = 'none'
                                THEN COALESCE(l.engagement_status, s.engagement_status)
                                ELSE s.engagement_status END,
      last_contact_date  = GREATEST(COALESCE(s.last_contact_date,  l.last_contact_date),
                                    COALESCE(l.last_contact_date,  s.last_contact_date)),
      next_followup_date = COALESCE(s.next_followup_date, l.next_followup_date),
      rate_increase_status       = CASE WHEN COALESCE(s.rate_increase_status,'none') = 'none'
                                        THEN COALESCE(l.rate_increase_status, s.rate_increase_status)
                                        ELSE s.rate_increase_status END,
      rate_increase_requested_at = CASE WHEN COALESCE(s.rate_increase_status,'none') = 'none'
                                        THEN l.rate_increase_requested_at ELSE s.rate_increase_requested_at END,
      rate_increase_requested_by = CASE WHEN COALESCE(s.rate_increase_status,'none') = 'none'
                                        THEN l.rate_increase_requested_by ELSE s.rate_increase_requested_by END,
      rate_increase_requested_by_email = CASE WHEN COALESCE(s.rate_increase_status,'none') = 'none'
                                        THEN l.rate_increase_requested_by_email ELSE s.rate_increase_requested_by_email END,
      rate_increase_approved_at  = CASE WHEN COALESCE(s.rate_increase_status,'none') = 'none'
                                        THEN l.rate_increase_approved_at ELSE s.rate_increase_approved_at END,
      rate_increase_approved_by  = CASE WHEN COALESCE(s.rate_increase_status,'none') = 'none'
                                        THEN l.rate_increase_approved_by ELSE s.rate_increase_approved_by END,
      rate_increase_proposed     = CASE WHEN COALESCE(s.rate_increase_status,'none') = 'none'
                                        THEN l.rate_increase_proposed ELSE s.rate_increase_proposed END,
      rate_increase_target_date  = CASE WHEN COALESCE(s.rate_increase_status,'none') = 'none'
                                        THEN l.rate_increase_target_date ELSE s.rate_increase_target_date END,
      rate_increase_note         = CASE WHEN COALESCE(s.rate_increase_status,'none') = 'none'
                                        THEN l.rate_increase_note ELSE s.rate_increase_note END,
      updated_at = NOW(), updated_by = auth.uid()
    WHERE agency_id = p_survivor_id;
    DELETE FROM home_health_agency_contracts WHERE agency_id = p_loser_id;
  END IF;

  -- Outreach history + prospect links follow the survivor.
  UPDATE agency_engagement_log SET agency_id = p_survivor_id WHERE agency_id = p_loser_id;
  UPDATE agency_prospects SET linked_agency_id = p_survivor_id WHERE linked_agency_id = p_loser_id;

  -- Remember the merge so imports can skip the dead id forever, and
  -- re-chain any older aliases that pointed at the loser.
  INSERT INTO agency_merge_aliases (loser_id, survivor_id, merged_by)
  VALUES (p_loser_id, p_survivor_id, auth.uid())
  ON CONFLICT (loser_id) DO UPDATE
    SET survivor_id = EXCLUDED.survivor_id, merged_at = now(), merged_by = EXCLUDED.merged_by;
  UPDATE agency_merge_aliases SET survivor_id = p_survivor_id WHERE survivor_id = p_loser_id;

  -- Goodbye duplicate (contract/history cascades are now empty).
  DELETE FROM home_health_agencies WHERE id = p_loser_id;
END $$;

REVOKE ALL ON FUNCTION public.merge_agencies(TEXT, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.merge_agencies(TEXT, TEXT) TO authenticated, service_role;

NOTIFY pgrst, 'reload schema';

COMMIT;
