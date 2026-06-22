-- Agency rate history + official TherapyBoss "Price list" import
-- =====================================================================
-- The Agencies tool's 6 front-facing rate columns (rate_ot_eval / _ot_assistant
-- / _pt_eval / _pt_assistant / _st_eval / _st_other on home_health_agency_contracts,
-- migration 30) were first loaded from a one-off HH-RATINGS sheet. This adds an
-- importer for the OFFICIAL TherapyBoss "Price list" export AND keeps rate history.
--
-- The TB export is long-format: one row per agency × episode type × service code ×
-- effective date → Bill rate. The client filters to **Private Home Health** episodes
-- (Dependable only bills private HHs; TB copies the same rate to every episode type)
-- and the 6 front-facing codes (OTF/OTFA/PTF/PTFA/STE/STEO), then sends the lines here.
--
-- This migration:
--   1. home_health_agency_rate_history — one row per (agency, bucket, effective_date),
--      the full effective-dated timeline (accumulates across future imports).
--   2. import_agency_price_list(p_rows) — match agency by normalize_agency_name,
--      upsert history lines, then set each contract's 6 rate columns to the
--      LATEST-effective rate per bucket. Returns {matched, unmatched, lines_imported}.
--   3. list_agency_rate_history(p_agency_id) — for the per-agency 🕘 history drawer.
--
-- Admin-only (matches the Agencies/Finance posture). Idempotent.

BEGIN;

-- ── 1. History table ───────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.home_health_agency_rate_history (
  id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  agency_id      TEXT NOT NULL REFERENCES public.home_health_agencies(id) ON DELETE CASCADE,
  bucket         TEXT NOT NULL CHECK (bucket IN
                   ('ot_eval','ot_assistant','pt_eval','pt_assistant','st_eval','st_other')),
  tb_type_code   TEXT,                 -- OTF / OTFA / PTF / PTFA / STE / STEO
  episode_type   TEXT,                 -- e.g. "Private Home Health"
  bill_rate      NUMERIC(10,2) NOT NULL CHECK (bill_rate >= 0),
  effective_date DATE NOT NULL,
  per_hour       BOOLEAN NOT NULL DEFAULT FALSE,
  source         TEXT NOT NULL DEFAULT 'therapyboss_price_list',
  imported_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  imported_by    UUID REFERENCES auth.users(id),
  -- One rate per (agency, bucket, effective_date): re-importing the same file is
  -- idempotent; a new effective date adds a history row.
  UNIQUE (agency_id, bucket, effective_date)
);

CREATE INDEX IF NOT EXISTS hharh_agency_bucket_idx
  ON public.home_health_agency_rate_history (agency_id, bucket, effective_date DESC);

ALTER TABLE public.home_health_agency_rate_history ENABLE ROW LEVEL SECURITY;

-- Admin-only read + write (all writes go through the SECURITY DEFINER RPCs).
DROP POLICY IF EXISTS "hharh_admin_all" ON public.home_health_agency_rate_history;
CREATE POLICY "hharh_admin_all" ON public.home_health_agency_rate_history
  FOR ALL TO authenticated
  USING (EXISTS (SELECT 1 FROM public.user_roles WHERE user_id = auth.uid() AND role = 'admin'))
  WITH CHECK (EXISTS (SELECT 1 FROM public.user_roles WHERE user_id = auth.uid() AND role = 'admin'));

-- ── 2. Import RPC ──────────────────────────────────────────────────
-- p_rows: JSONB array of line objects:
--   { agency_name, agency_id?, bucket, tb_type_code, episode_type,
--     bill_rate, effective_date (YYYY-MM-DD), per_hour }
CREATE OR REPLACE FUNCTION public.import_agency_price_list(p_rows JSONB)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_is_admin BOOLEAN;
  v_matched  INT;
  v_lines    INT;
  v_unmatched JSONB;
BEGIN
  SELECT EXISTS (SELECT 1 FROM public.user_roles WHERE user_id = auth.uid() AND role = 'admin')
    INTO v_is_admin;
  IF NOT v_is_admin THEN
    RAISE EXCEPTION 'Admin only';
  END IF;

  -- Normalize the inbound payload + resolve agency_id (explicit override wins,
  -- else normalized-name match against the portal agencies).
  CREATE TEMP TABLE _incoming ON COMMIT DROP AS
  SELECT
    COALESCE(
      NULLIF(elem->>'agency_id', ''),
      (SELECT a.id FROM public.home_health_agencies a
        WHERE public.normalize_agency_name(a.name) = public.normalize_agency_name(elem->>'agency_name')
        LIMIT 1)
    )                                   AS agency_id,
    NULLIF(elem->>'agency_name','')     AS agency_name,
    elem->>'bucket'                     AS bucket,
    NULLIF(elem->>'tb_type_code','')    AS tb_type_code,
    NULLIF(elem->>'episode_type','')    AS episode_type,
    (elem->>'bill_rate')::numeric       AS bill_rate,
    (elem->>'effective_date')::date     AS effective_date,
    (lower(COALESCE(elem->>'per_hour','')) IN ('true','t','y','yes','1')) AS per_hour
  FROM jsonb_array_elements(p_rows) elem
  WHERE elem->>'bucket' IN ('ot_eval','ot_assistant','pt_eval','pt_assistant','st_eval','st_other')
    AND (elem->>'bill_rate') IS NOT NULL
    AND (elem->>'effective_date') IS NOT NULL;

  -- Upsert history (matched lines only).
  INSERT INTO public.home_health_agency_rate_history
    (agency_id, bucket, tb_type_code, episode_type, bill_rate, effective_date, per_hour, imported_by)
  SELECT agency_id, bucket, tb_type_code, episode_type, bill_rate, effective_date, per_hour, auth.uid()
  FROM _incoming
  WHERE agency_id IS NOT NULL AND bill_rate > 0
  ON CONFLICT (agency_id, bucket, effective_date) DO UPDATE
    SET bill_rate    = EXCLUDED.bill_rate,
        tb_type_code = EXCLUDED.tb_type_code,
        episode_type = EXCLUDED.episode_type,
        per_hour     = EXCLUDED.per_hour,
        imported_at  = now(),
        imported_by  = auth.uid();
  GET DIAGNOSTICS v_lines = ROW_COUNT;

  -- Make sure every touched agency has a contract row.
  INSERT INTO public.home_health_agency_contracts (agency_id)
  SELECT DISTINCT agency_id FROM _incoming WHERE agency_id IS NOT NULL
  ON CONFLICT (agency_id) DO NOTHING;

  -- Derive the 6 front-facing columns from the LATEST-effective history rate per
  -- bucket (recomputed from history → idempotent + correct). TB is source of truth.
  WITH latest AS (
    SELECT DISTINCT ON (h.agency_id, h.bucket)
           h.agency_id, h.bucket, h.bill_rate
    FROM public.home_health_agency_rate_history h
    WHERE h.agency_id IN (SELECT DISTINCT agency_id FROM _incoming WHERE agency_id IS NOT NULL)
    ORDER BY h.agency_id, h.bucket, h.effective_date DESC
  ), piv AS (
    SELECT agency_id,
      MAX(bill_rate) FILTER (WHERE bucket='ot_eval')      AS ot_eval,
      MAX(bill_rate) FILTER (WHERE bucket='ot_assistant') AS ot_assistant,
      MAX(bill_rate) FILTER (WHERE bucket='pt_eval')      AS pt_eval,
      MAX(bill_rate) FILTER (WHERE bucket='pt_assistant') AS pt_assistant,
      MAX(bill_rate) FILTER (WHERE bucket='st_eval')      AS st_eval,
      MAX(bill_rate) FILTER (WHERE bucket='st_other')     AS st_other
    FROM latest GROUP BY agency_id
  )
  UPDATE public.home_health_agency_contracts c
     SET rate_ot_eval      = COALESCE(piv.ot_eval,      c.rate_ot_eval),
         rate_ot_assistant = COALESCE(piv.ot_assistant, c.rate_ot_assistant),
         rate_pt_eval      = COALESCE(piv.pt_eval,      c.rate_pt_eval),
         rate_pt_assistant = COALESCE(piv.pt_assistant, c.rate_pt_assistant),
         rate_st_eval      = COALESCE(piv.st_eval,      c.rate_st_eval),
         rate_st_other     = COALESCE(piv.st_other,     c.rate_st_other),
         updated_at        = now(),
         updated_by        = auth.uid()
  FROM piv WHERE c.agency_id = piv.agency_id;

  SELECT COUNT(DISTINCT agency_id) INTO v_matched FROM _incoming WHERE agency_id IS NOT NULL;

  SELECT COALESCE(jsonb_agg(DISTINCT jsonb_build_object('name', agency_name)), '[]'::jsonb)
    INTO v_unmatched FROM _incoming WHERE agency_id IS NULL;

  RETURN jsonb_build_object('matched', v_matched, 'unmatched', v_unmatched, 'lines_imported', v_lines);
END;
$$;

REVOKE ALL ON FUNCTION public.import_agency_price_list(JSONB) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.import_agency_price_list(JSONB) TO authenticated;

-- ── 3. History read RPC (per-agency drawer) ────────────────────────
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
    AND EXISTS (SELECT 1 FROM public.user_roles WHERE user_id = auth.uid() AND role = 'admin')
  ORDER BY bucket, effective_date DESC;
$$;

REVOKE ALL ON FUNCTION public.list_agency_rate_history(TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.list_agency_rate_history(TEXT) TO authenticated;

COMMIT;
