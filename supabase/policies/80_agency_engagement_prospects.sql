-- ════════════════════════════════════════════════════════════════════
-- 80 · Agencies: locked rates + rate-increase workflow + engagement
--      tracking + prospects pipeline  (requires migrations 78 + 79)
--
-- 1. Rates become import-only: the 6 rate_* fields leave the
--    update_agency_contract whitelist — the TB Price List import is
--    the single writer. Hand corrections are replaced by a workflow:
--    request (admin/edit grantee) → approve (ADMIN, timestamped) →
--    the agency carries an "import TB rates" flag until cleared.
-- 2. Engagement tracking on current agencies: status + last-contact +
--    next-follow-up columns (editable via the whitelist) and a shared
--    timestamped outreach log table.
-- 3. Prospects: potential agencies being marketed to, with their own
--    pipeline, log entries, and a linked_agency_id set when the
--    contract completes (log entries migrate to the agency).
--
-- Access: read = admin or any agency grant (78); write = admin or
-- ✏️ edit grantee (79); rate-increase APPROVE = admin only.
-- Idempotent. list_agency_contracts is DROP-then-CREATE because its
-- RETURNS TABLE shape grows (42P13 — same precedent as 47/48).
-- ════════════════════════════════════════════════════════════════════
BEGIN;

-- ── 1. Contract columns: engagement + rate-increase workflow ─────────
ALTER TABLE public.home_health_agency_contracts
  ADD COLUMN IF NOT EXISTS engagement_status        TEXT NOT NULL DEFAULT 'none',
  ADD COLUMN IF NOT EXISTS last_contact_date        DATE,
  ADD COLUMN IF NOT EXISTS next_followup_date       DATE,
  ADD COLUMN IF NOT EXISTS rate_increase_status     TEXT NOT NULL DEFAULT 'none',
  ADD COLUMN IF NOT EXISTS rate_increase_requested_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS rate_increase_requested_by UUID,
  ADD COLUMN IF NOT EXISTS rate_increase_approved_at  TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS rate_increase_approved_by  UUID;

ALTER TABLE public.home_health_agency_contracts
  DROP CONSTRAINT IF EXISTS hhac_engagement_status_check;
ALTER TABLE public.home_health_agency_contracts
  ADD CONSTRAINT hhac_engagement_status_check
  CHECK (engagement_status IN ('none', 'reaching_out', 'engaged', 'dormant'));

ALTER TABLE public.home_health_agency_contracts
  DROP CONSTRAINT IF EXISTS hhac_rate_increase_status_check;
ALTER TABLE public.home_health_agency_contracts
  ADD CONSTRAINT hhac_rate_increase_status_check
  CHECK (rate_increase_status IN ('none', 'requested', 'approved'));

-- ── 2. update_agency_contract: rates OUT, engagement fields IN ──────
-- Body identical to migration 79 otherwise (admin OR edit-grantee).
CREATE OR REPLACE FUNCTION public.update_agency_contract(
  p_agency_id TEXT,
  p_field     TEXT,
  p_value     JSONB
)
RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  allowed_fields TEXT[] := ARRAY[
    -- rate_* fields removed on purpose: TB Price List import only.
    'rating_payment','rating_communication',
    'contract_location','is_active','contract_start_year',
    'preferred_payment_method','sent_via','collections_contact',
    'notes',
    'engagement_status','last_contact_date','next_followup_date'
  ];
  col_type       TEXT;
  scalar_text    TEXT;
BEGIN
  IF NOT (
    EXISTS (SELECT 1 FROM user_roles ur
            WHERE ur.user_id = auth.uid() AND ur.role = 'admin')
    OR EXISTS (SELECT 1 FROM agency_viewers av
               WHERE av.user_id = auth.uid() AND av.access = 'edit')
  ) THEN
    RAISE EXCEPTION 'Only admin or granted editors may edit agency contracts';
  END IF;

  IF NOT (p_field = ANY(allowed_fields)) THEN
    RAISE EXCEPTION 'Field % is not editable', p_field;
  END IF;

  INSERT INTO home_health_agency_contracts (agency_id)
  VALUES (p_agency_id)
  ON CONFLICT (agency_id) DO NOTHING;

  col_type := CASE
    WHEN p_field IN ('rating_payment','rating_communication',
                     'contract_start_year')                             THEN 'SMALLINT'
    WHEN p_field = 'is_active'                                          THEN 'BOOLEAN'
    WHEN p_field IN ('last_contact_date','next_followup_date')          THEN 'DATE'
    ELSE                                                                     'TEXT'
  END;

  IF p_value IS NULL OR jsonb_typeof(p_value) = 'null' THEN
    scalar_text := NULL;
  ELSE
    scalar_text := p_value #>> '{}';
  END IF;

  EXECUTE format(
    'UPDATE home_health_agency_contracts
       SET %I = $1::%s,
           updated_at = NOW(),
           updated_by = auth.uid()
     WHERE agency_id = $2',
    p_field,
    col_type
  )
  USING scalar_text, p_agency_id;
END $$;

REVOKE ALL ON FUNCTION public.update_agency_contract(TEXT, TEXT, JSONB) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.update_agency_contract(TEXT, TEXT, JSONB) TO authenticated, service_role;

-- ── 3. set_rate_increase: request / approve / clear ──────────────────
CREATE OR REPLACE FUNCTION public.set_rate_increase(
  p_agency_id TEXT,
  p_action    TEXT   -- 'request' | 'approve' | 'clear'
)
RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  is_admin BOOLEAN := EXISTS (SELECT 1 FROM user_roles ur
                              WHERE ur.user_id = auth.uid() AND ur.role = 'admin');
  is_editor BOOLEAN := EXISTS (SELECT 1 FROM agency_viewers av
                               WHERE av.user_id = auth.uid() AND av.access = 'edit');
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
           rate_increase_approved_at = NULL,
           rate_increase_approved_by = NULL,
           updated_at = NOW(), updated_by = auth.uid()
     WHERE agency_id = p_agency_id;
  ELSIF p_action = 'approve' THEN
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
           rate_increase_approved_at = NULL,
           rate_increase_approved_by = NULL,
           updated_at = NOW(), updated_by = auth.uid()
     WHERE agency_id = p_agency_id;
  END IF;
END $$;

REVOKE ALL ON FUNCTION public.set_rate_increase(TEXT, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.set_rate_increase(TEXT, TEXT) TO authenticated, service_role;

-- ── 4. list_agency_contracts: return the new columns ─────────────────
-- DROP first: the RETURNS TABLE shape grows (42P13).
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
  rate_increase_approved_at  TIMESTAMPTZ
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
      c.rate_increase_status, c.rate_increase_requested_at, c.rate_increase_approved_at
    FROM home_health_agencies a
    LEFT JOIN home_health_agency_contracts c ON c.agency_id = a.id
    ORDER BY a.name NULLS LAST;
END $$;

REVOKE ALL ON FUNCTION public.list_agency_contracts() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.list_agency_contracts() TO authenticated, service_role;

-- ── 5. Prospects ──────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.agency_prospects (
  id                 UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name               TEXT NOT NULL,
  city               TEXT,
  state              TEXT,
  zip                TEXT,
  contact_name       TEXT,
  contact_phone      TEXT,
  contact_email      TEXT,
  status             TEXT NOT NULL DEFAULT 'new',
  last_contact_date  DATE,
  next_followup_date DATE,
  notes              TEXT,
  linked_agency_id   TEXT REFERENCES public.home_health_agencies(id),
  created_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
  created_by         UUID,
  updated_at         TIMESTAMPTZ NOT NULL DEFAULT now()
);

ALTER TABLE public.agency_prospects
  DROP CONSTRAINT IF EXISTS agency_prospects_status_check;
ALTER TABLE public.agency_prospects
  ADD CONSTRAINT agency_prospects_status_check
  CHECK (status IN ('new','contacted','in_discussions','contract_sent','signed','not_interested'));

ALTER TABLE public.agency_prospects ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "agency_prospects_read" ON public.agency_prospects;
CREATE POLICY "agency_prospects_read" ON public.agency_prospects
  FOR SELECT TO authenticated
  USING (EXISTS (SELECT 1 FROM public.user_roles
                 WHERE user_id = auth.uid() AND role = 'admin')
         OR EXISTS (SELECT 1 FROM public.agency_viewers WHERE user_id = auth.uid()));

DROP POLICY IF EXISTS "agency_prospects_write" ON public.agency_prospects;
CREATE POLICY "agency_prospects_write" ON public.agency_prospects
  FOR ALL TO authenticated
  USING (EXISTS (SELECT 1 FROM public.user_roles
                 WHERE user_id = auth.uid() AND role = 'admin')
         OR EXISTS (SELECT 1 FROM public.agency_viewers
                    WHERE user_id = auth.uid() AND access = 'edit'))
  WITH CHECK (EXISTS (SELECT 1 FROM public.user_roles
                      WHERE user_id = auth.uid() AND role = 'admin')
              OR EXISTS (SELECT 1 FROM public.agency_viewers
                         WHERE user_id = auth.uid() AND access = 'edit'));

-- ── 6. Shared engagement log (current agencies AND prospects) ────────
CREATE TABLE IF NOT EXISTS public.agency_engagement_log (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  agency_id   TEXT REFERENCES public.home_health_agencies(id),
  prospect_id UUID REFERENCES public.agency_prospects(id) ON DELETE CASCADE,
  note        TEXT NOT NULL,
  noted_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  noted_by    UUID,
  -- Stamped by the client at insert time so every reader can show the
  -- author (resolving UUIDs needs the admin-only list_staff RPC).
  noted_by_email TEXT,
  CHECK ((agency_id IS NULL) <> (prospect_id IS NULL))
);
ALTER TABLE public.agency_engagement_log
  ADD COLUMN IF NOT EXISTS noted_by_email TEXT;

CREATE INDEX IF NOT EXISTS ael_agency_idx   ON public.agency_engagement_log (agency_id, noted_at DESC);
CREATE INDEX IF NOT EXISTS ael_prospect_idx ON public.agency_engagement_log (prospect_id, noted_at DESC);

ALTER TABLE public.agency_engagement_log ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "ael_read" ON public.agency_engagement_log;
CREATE POLICY "ael_read" ON public.agency_engagement_log
  FOR SELECT TO authenticated
  USING (EXISTS (SELECT 1 FROM public.user_roles
                 WHERE user_id = auth.uid() AND role = 'admin')
         OR EXISTS (SELECT 1 FROM public.agency_viewers WHERE user_id = auth.uid()));

DROP POLICY IF EXISTS "ael_write" ON public.agency_engagement_log;
CREATE POLICY "ael_write" ON public.agency_engagement_log
  FOR ALL TO authenticated
  USING (EXISTS (SELECT 1 FROM public.user_roles
                 WHERE user_id = auth.uid() AND role = 'admin')
         OR EXISTS (SELECT 1 FROM public.agency_viewers
                    WHERE user_id = auth.uid() AND access = 'edit'))
  WITH CHECK (EXISTS (SELECT 1 FROM public.user_roles
                      WHERE user_id = auth.uid() AND role = 'admin')
              OR EXISTS (SELECT 1 FROM public.agency_viewers
                         WHERE user_id = auth.uid() AND access = 'edit'));

NOTIFY pgrst, 'reload schema';

COMMIT;
