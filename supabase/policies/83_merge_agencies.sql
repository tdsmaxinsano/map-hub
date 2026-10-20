-- ════════════════════════════════════════════════════════════════════
-- 83 · merge_agencies: fold a duplicate agency into the surviving row
--      (requires migrations 46 + 80; admin-only)
--
-- Agency ids are deterministic slugs built from name + zip/city, so an
-- agency that MOVES (address updated in TherapyBoss) gets a brand-new
-- row on the next import — the old row keeps the ratings, notes,
-- engagement and history. This RPC moves everything from the losing
-- row onto the survivor and deletes the loser:
--   · rate history rows move (survivor wins (bucket, effective_date)
--     collisions — its imports are the fresh ones)
--   · the contract merges column-by-column: survivor's values win,
--     NULLs fill from the loser; notes concatenate when both exist
--   · engagement-log rows and prospect links repoint
--   · the loser is deleted (its now-empty contract/history cascade)
-- Everything else in the portal references agencies by NAME, so no
-- other repointing is needed. Idempotent (CREATE OR REPLACE).
-- ════════════════════════════════════════════════════════════════════
BEGIN;

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

  -- ── Rate history: move, survivor wins collisions ────────────────────
  INSERT INTO home_health_agency_rate_history
    (agency_id, bucket, tb_type_code, episode_type, bill_rate,
     effective_date, per_hour, source, imported_at, imported_by)
  SELECT p_survivor_id, h.bucket, h.tb_type_code, h.episode_type, h.bill_rate,
         h.effective_date, h.per_hour, h.source, h.imported_at, h.imported_by
    FROM home_health_agency_rate_history h
   WHERE h.agency_id = p_loser_id
  ON CONFLICT (agency_id, bucket, effective_date) DO NOTHING;
  DELETE FROM home_health_agency_rate_history WHERE agency_id = p_loser_id;

  -- ── Contract: move it over, or coalesce-fill the survivor's ─────────
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

  -- ── Outreach history + prospect links follow the survivor ───────────
  UPDATE agency_engagement_log SET agency_id = p_survivor_id WHERE agency_id = p_loser_id;
  UPDATE agency_prospects SET linked_agency_id = p_survivor_id WHERE linked_agency_id = p_loser_id;

  -- ── Goodbye duplicate (contract/history cascades are now empty) ──────
  DELETE FROM home_health_agencies WHERE id = p_loser_id;
END $$;

REVOKE ALL ON FUNCTION public.merge_agencies(TEXT, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.merge_agencies(TEXT, TEXT) TO authenticated, service_role;

NOTIFY pgrst, 'reload schema';

COMMIT;
