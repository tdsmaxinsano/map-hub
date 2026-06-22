-- Agencies — also expose the FIRST (earliest) effective date
-- =====================================================================
-- Migration 47 added rates_effective_date (= MAX effective_date) for the "last
-- rate update" surface. The Agencies table now shows a Start column (first
-- effective contract date) + a Latest Eff. column (most recent), so we also need
-- the MIN. Rebuild list_agency_contracts() to add a trailing
-- `rates_effective_date_first DATE` = MIN(effective_date) per agency from the
-- imported TB price-list history.
--
-- Additive (new trailing return column) + idempotent (CREATE OR REPLACE).

BEGIN;

-- DROP first: adding a column to a RETURNS TABLE function changes its return
-- type, which CREATE OR REPLACE cannot do ("cannot change return type of
-- existing function"). The function is only called via RPC (no DB dependents),
-- so dropping it is safe.
DROP FUNCTION IF EXISTS public.list_agency_contracts();
CREATE OR REPLACE FUNCTION public.list_agency_contracts()
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
  rates_effective_date_first DATE
)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM user_roles ur
                 WHERE ur.user_id = auth.uid() AND ur.role = 'admin') THEN
    RAISE EXCEPTION 'Only admin may list agency contracts';
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
        WHERE h.agency_id = a.id)  AS rates_effective_date_first
    FROM home_health_agencies a
    LEFT JOIN home_health_agency_contracts c ON c.agency_id = a.id
    ORDER BY a.name NULLS LAST;
END $$;

REVOKE ALL ON FUNCTION public.list_agency_contracts() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.list_agency_contracts() TO authenticated;

COMMIT;
