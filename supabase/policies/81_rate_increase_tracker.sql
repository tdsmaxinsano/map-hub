-- ════════════════════════════════════════════════════════════════════
-- 81 · Rate-increase TRACKER (requires migration 80)
--
-- A request now carries substance: WHICH rates are proposed (current →
-- proposed, JSONB of only the changed buckets), WHEN the increase is
-- planned to take effect (target date), a free-text note, and WHO asked
-- (email stamped server-side so non-admin grantees can see it without
-- the admin-only list_staff RPC).
--
-- set_rate_increase grows three optional params — the old 2-arg call
-- shape still works via DEFAULTs, so the currently deployed page keeps
-- functioning between running this SQL and merging the new page.
-- The old (TEXT, TEXT) signature is dropped first (an added-param
-- CREATE would otherwise make an ambiguous overload).
-- list_agency_contracts is DROP-then-CREATE because its RETURNS TABLE
-- shape grows (42P13 — precedent: migrations 47/48/80). Idempotent.
-- ════════════════════════════════════════════════════════════════════
BEGIN;

-- ── 1. Tracker columns ────────────────────────────────────────────────
ALTER TABLE public.home_health_agency_contracts
  ADD COLUMN IF NOT EXISTS rate_increase_proposed           JSONB,
  ADD COLUMN IF NOT EXISTS rate_increase_target_date        DATE,
  ADD COLUMN IF NOT EXISTS rate_increase_note               TEXT,
  ADD COLUMN IF NOT EXISTS rate_increase_requested_by_email TEXT;

-- ── 2. set_rate_increase: request now carries proposal/target/note ───
DROP FUNCTION IF EXISTS public.set_rate_increase(TEXT, TEXT);
DROP FUNCTION IF EXISTS public.set_rate_increase(TEXT, TEXT, JSONB, DATE, TEXT);
CREATE FUNCTION public.set_rate_increase(
  p_agency_id   TEXT,
  p_action      TEXT,            -- 'request' | 'approve' | 'clear'
  p_proposal    JSONB DEFAULT NULL,   -- {"rate_pt_eval": 120, ...} changed buckets only
  p_target_date DATE  DEFAULT NULL,   -- planned effective date
  p_note        TEXT  DEFAULT NULL
)
RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  is_admin BOOLEAN := EXISTS (SELECT 1 FROM user_roles ur
                              WHERE ur.user_id = auth.uid() AND ur.role = 'admin');
  is_editor BOOLEAN := EXISTS (SELECT 1 FROM agency_viewers av
                               WHERE av.user_id = auth.uid() AND av.access = 'edit');
  requester_email TEXT := (SELECT u.email FROM auth.users u WHERE u.id = auth.uid());
BEGIN
  IF p_action NOT IN ('request', 'approve', 'clear') THEN
    RAISE EXCEPTION 'Unknown action %', p_action;
  END IF;
  IF p_action = 'approve' AND NOT is_admin THEN
    RAISE EXCEPTION 'Only admin may approve a rate increase';
  END IF;
  IF p_action IN ('request', 'clear') AND NOT (is_admin OR is_editor) THEN
    RAISE EXCEPTION 'Only admin or granted editors may % a rate increase', p_action;
  END IF;

  INSERT INTO home_health_agency_contracts (agency_id)
  VALUES (p_agency_id)
  ON CONFLICT (agency_id) DO NOTHING;

  IF p_action = 'request' THEN
    UPDATE home_health_agency_contracts
       SET rate_increase_status = 'requested',
           rate_increase_requested_at = NOW(),
           rate_increase_requested_by = auth.uid(),
           rate_increase_requested_by_email = requester_email,
           rate_increase_proposed = p_proposal,
           rate_increase_target_date = p_target_date,
           rate_increase_note = p_note,
           rate_increase_approved_at = NULL,
           rate_increase_approved_by = NULL,
           updated_at = NOW(), updated_by = auth.uid()
     WHERE agency_id = p_agency_id;
  ELSIF p_action = 'approve' THEN
    -- Proposal/target/note stay — the tracker shows them until cleared.
    UPDATE home_health_agency_contracts
       SET rate_increase_status = 'approved',
           rate_increase_approved_at = NOW(),
           rate_increase_approved_by = auth.uid(),
           updated_at = NOW(), updated_by = auth.uid()
     WHERE agency_id = p_agency_id;
  ELSE
    UPDATE home_health_agency_contracts
       SET rate_increase_status = 'none',
           rate_increase_requested_at = NULL,
           rate_increase_requested_by = NULL,
           rate_increase_requested_by_email = NULL,
           rate_increase_proposed = NULL,
           rate_increase_target_date = NULL,
           rate_increase_note = NULL,
           rate_increase_approved_at = NULL,
           rate_increase_approved_by = NULL,
           updated_at = NOW(), updated_by = auth.uid()
     WHERE agency_id = p_agency_id;
  END IF;
END $$;

REVOKE ALL ON FUNCTION public.set_rate_increase(TEXT, TEXT, JSONB, DATE, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.set_rate_increase(TEXT, TEXT, JSONB, DATE, TEXT) TO authenticated, service_role;

-- ── 3. list_agency_contracts: return the tracker columns ─────────────
DROP FUNCTION IF EXISTS public.list_agency_contracts();
CREATE FUNCTION public.list_agency_contracts()
RETURNS TABLE (
  agency_id              TEXT,
  agency_name            TEXT,
  agency_active          BOOLEAN,
  agency_city            TEXT,
  agency_state           TEXT,
  agency_zip             TEXT,
  contract_id            UUID,
  rate_ot_eval           NUMERIC,
  rate_ot_assistant      NUMERIC,
  rate_pt_eval           NUMERIC,
  rate_pt_assistant      NUMERIC,
  rate_st_eval           NUMERIC,
  rate_st_other          NUMERIC,
  rating_payment         SMALLINT,
  rating_communication   SMALLINT,
  contract_location      TEXT,
  is_active              BOOLEAN,
  contract_start_year    SMALLINT,
  preferred_payment_method TEXT,
  sent_via               TEXT,
  collections_contact    TEXT,
  notes                  TEXT,
  updated_at             TIMESTAMPTZ,
  rates_effective_date   DATE,
  rates_effective_date_first DATE,
  engagement_status      TEXT,
  last_contact_date      DATE,
  next_followup_date     DATE,
  rate_increase_status   TEXT,
  rate_increase_requested_at TIMESTAMPTZ,
  rate_increase_approved_at  TIMESTAMPTZ,
  rate_increase_proposed           JSONB,
  rate_increase_target_date        DATE,
  rate_increase_note               TEXT,
  rate_increase_requested_by_email TEXT
)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT (
    EXISTS (SELECT 1 FROM user_roles ur
            WHERE ur.user_id = auth.uid() AND ur.role = 'admin')
    OR EXISTS (SELECT 1 FROM agency_viewers av WHERE av.user_id = auth.uid())
  ) THEN
    RAISE EXCEPTION 'Only admin or granted viewers may list agency contracts';
  END IF;

  RETURN QUERY
    SELECT
      a.id                  AS agency_id,
      a.name                AS agency_name,
      a.active              AS agency_active,
      a.city                AS agency_city,
      a.state               AS agency_state,
      a.zip                 AS agency_zip,
      c.id                  AS contract_id,
      c.rate_ot_eval, c.rate_ot_assistant,
      c.rate_pt_eval, c.rate_pt_assistant,
      c.rate_st_eval, c.rate_st_other,
      c.rating_payment, c.rating_communication,
      c.contract_location, c.is_active, c.contract_start_year,
      c.preferred_payment_method, c.sent_via, c.collections_contact,
      c.notes, c.updated_at,
      (SELECT MAX(h.effective_date)
         FROM home_health_agency_rate_history h
        WHERE h.agency_id = a.id)  AS rates_effective_date,
      (SELECT MIN(h.effective_date)
         FROM home_health_agency_rate_history h
        WHERE h.agency_id = a.id)  AS rates_effective_date_first,
      c.engagement_status, c.last_contact_date, c.next_followup_date,
      c.rate_increase_status, c.rate_increase_requested_at, c.rate_increase_approved_at,
      c.rate_increase_proposed, c.rate_increase_target_date,
      c.rate_increase_note, c.rate_increase_requested_by_email
    FROM home_health_agencies a
    LEFT JOIN home_health_agency_contracts c ON c.agency_id = a.id
    ORDER BY a.name NULLS LAST;
END $$;

REVOKE ALL ON FUNCTION public.list_agency_contracts() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.list_agency_contracts() TO authenticated, service_role;

NOTIFY pgrst, 'reload schema';

COMMIT;
