-- ════════════════════════════════════════════════════════════════════
-- 78 · Agency VIEWER allowlist — let specific non-admins VIEW Agencies
--
-- The 🏢 Agencies tool stays admin-managed, but named users (e.g. one
-- trusted editor) can now be granted read-only access: they see the
-- table + rate history, with every editor/import affordance disabled
-- client-side AND all write RPCs still hard admin-only server-side.
--
-- Grant someone (fill in their email):
--   INSERT INTO public.agency_viewers (user_id, granted_by)
--   SELECT id, auth.uid() FROM auth.users WHERE email = 'PERSON@EMAIL'
--   ON CONFLICT (user_id) DO NOTHING;
-- Revoke:
--   DELETE FROM public.agency_viewers
--   WHERE user_id = (SELECT id FROM auth.users WHERE email = 'PERSON@EMAIL');
--
-- Idempotent. Rebuilds the two READ RPCs (same return shapes → plain
-- CREATE OR REPLACE) to accept admin OR allowlisted viewer.
-- ════════════════════════════════════════════════════════════════════
BEGIN;

-- ── 1. Allowlist table ───────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.agency_viewers (
  user_id    UUID PRIMARY KEY,
  granted_by UUID,
  granted_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

ALTER TABLE public.agency_viewers ENABLE ROW LEVEL SECURITY;

-- A user may see their own grant (the shell/page check); admins see all.
DROP POLICY IF EXISTS "agency_viewers_self_or_admin_read" ON public.agency_viewers;
CREATE POLICY "agency_viewers_self_or_admin_read" ON public.agency_viewers
  FOR SELECT TO authenticated
  USING (user_id = auth.uid()
         OR EXISTS (SELECT 1 FROM public.user_roles
                    WHERE user_id = auth.uid() AND role = 'admin'));

-- Only admins manage grants.
DROP POLICY IF EXISTS "agency_viewers_admin_write" ON public.agency_viewers;
CREATE POLICY "agency_viewers_admin_write" ON public.agency_viewers
  FOR ALL TO authenticated
  USING      (EXISTS (SELECT 1 FROM public.user_roles
                      WHERE user_id = auth.uid() AND role = 'admin'))
  WITH CHECK (EXISTS (SELECT 1 FROM public.user_roles
                      WHERE user_id = auth.uid() AND role = 'admin'));

-- ── 2. list_agency_contracts(): admin OR allowlisted viewer ──────────
-- Body identical to migration 48; only the access check changes.
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
        WHERE h.agency_id = a.id)  AS rates_effective_date_first
    FROM home_health_agencies a
    LEFT JOIN home_health_agency_contracts c ON c.agency_id = a.id
    ORDER BY a.name NULLS LAST;
END $$;

REVOKE ALL ON FUNCTION public.list_agency_contracts() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.list_agency_contracts() TO authenticated, service_role;

-- ── 3. list_agency_rate_history(): admin OR allowlisted viewer ───────
CREATE OR REPLACE FUNCTION public.list_agency_rate_history(p_agency_id TEXT)
RETURNS TABLE(
  bucket         TEXT,
  tb_type_code   TEXT,
  episode_type   TEXT,
  bill_rate      NUMERIC,
  effective_date DATE,
  per_hour       BOOLEAN,
  imported_at    TIMESTAMPTZ
)
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT bucket, tb_type_code, episode_type, bill_rate, effective_date, per_hour, imported_at
  FROM public.home_health_agency_rate_history
  WHERE agency_id = p_agency_id
    AND (
      EXISTS (SELECT 1 FROM public.user_roles WHERE user_id = auth.uid() AND role = 'admin')
      OR EXISTS (SELECT 1 FROM public.agency_viewers WHERE user_id = auth.uid())
    )
  ORDER BY bucket, effective_date DESC;
$$;

REVOKE ALL ON FUNCTION public.list_agency_rate_history(TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.list_agency_rate_history(TEXT) TO authenticated, service_role;

-- Write RPCs (update_agency_contract / upsert_agency_contracts /
-- import_agency_price_list) stay admin-only — deliberately untouched.

NOTIFY pgrst, 'reload schema';

COMMIT;
