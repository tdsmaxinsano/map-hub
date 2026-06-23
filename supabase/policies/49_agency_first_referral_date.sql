-- Agencies — recommend a Start date from the earliest referral on record
-- =====================================================================
-- The price-list effective date is a poor "start" (it's just when current rates
-- were set). A much better signal is the agency's FIRST referral. The richest
-- history is the TherapyBoss completed-services import (one row per patient
-- episode), which carries the source agency (`referral_source`) + dates
-- (`referral_date`, `start_of_episode`).
--
-- This rebuilds list_agency_contracts() to add a trailing `first_referral_date`
-- = the earliest plausible (>= 2000-01-01) referral/episode date per agency,
-- matched by normalize_agency_name(referral_source) = normalize_agency_name(name).
-- The client shows it as a "📥 yyyy · 1st referral" recommendation ONLY when the
-- Start year is blank or the referral is earlier than what's already set.
--
-- DROP-then-CREATE (return-type change). Idempotent.

BEGIN;

-- Exception-safe date parse: the completed-services date columns can hold mixed
-- DATE/TEXT/malformed values (see migration 43), and a bad cast would error the
-- whole RPC. This grabs a YYYY-MM-DD prefix and returns NULL on any failure.
CREATE OR REPLACE FUNCTION public.try_parse_date(p TEXT)
RETURNS DATE
LANGUAGE plpgsql IMMUTABLE
AS $$
BEGIN
  RETURN (substring(p FROM '^\d{4}-\d{2}-\d{2}'))::date;
EXCEPTION WHEN others THEN
  RETURN NULL;
END $$;

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
  rates_effective_date_first DATE,
  first_referral_date    DATE
)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM user_roles ur
                 WHERE ur.user_id = auth.uid() AND ur.role = 'admin') THEN
    RAISE EXCEPTION 'Only admin may list agency contracts';
  END IF;

  RETURN QUERY
    WITH refdates AS (
      -- Earliest plausible referral/episode date per normalized agency name.
      SELECT nname, MIN(d) AS first_ref
      FROM (
        SELECT normalize_agency_name(referral_source) AS nname,
               try_parse_date(referral_date::text)    AS d
          FROM therapy_boss_completed_service_import_rows
         WHERE referral_source IS NOT NULL AND referral_source <> ''
        UNION ALL
        SELECT normalize_agency_name(referral_source),
               try_parse_date(start_of_episode::text)
          FROM therapy_boss_completed_service_import_rows
         WHERE referral_source IS NOT NULL AND referral_source <> ''
      ) z
      WHERE d IS NOT NULL AND d >= DATE '2000-01-01'
      GROUP BY nname
    )
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
      (SELECT MAX(h.effective_date) FROM home_health_agency_rate_history h WHERE h.agency_id = a.id) AS rates_effective_date,
      (SELECT MIN(h.effective_date) FROM home_health_agency_rate_history h WHERE h.agency_id = a.id) AS rates_effective_date_first,
      rd.first_ref          AS first_referral_date
    FROM home_health_agencies a
    LEFT JOIN home_health_agency_contracts c ON c.agency_id = a.id
    LEFT JOIN refdates rd ON rd.nname = normalize_agency_name(a.name)
    ORDER BY a.name NULLS LAST;
END $$;

REVOKE ALL ON FUNCTION public.list_agency_contracts() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.list_agency_contracts() TO authenticated;

COMMIT;
