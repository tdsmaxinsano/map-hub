-- Agencies — surface the rate effective date ("last rate update")
-- =====================================================================
-- Rates are negotiated together, so each agency effectively has one rate
-- effective date. Instead of the 🕘 history clock, the table shows that date
-- inline. This rebuilds list_agency_contracts() (migration 30) to also return
-- rates_effective_date = the latest effective_date across the agency's imported
-- TB price-list rates (home_health_agency_rate_history, migration 46).
--
-- Additive (new trailing return column) + idempotent (CREATE OR REPLACE).

BEGIN;

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
  rates_effective_date   DATE
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
        WHERE h.agency_id = a.id)  AS rates_effective_date
    FROM home_health_agencies a
    LEFT JOIN home_health_agency_contracts c ON c.agency_id = a.id
    ORDER BY a.name NULLS LAST;
END $$;

REVOKE ALL ON FUNCTION public.list_agency_contracts() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.list_agency_contracts() TO authenticated;

COMMIT;
