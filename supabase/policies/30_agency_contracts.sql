-- Home Health Agency Contracts (per-discipline rates + payment behavior + collections)
-- =====================================================================
-- Backs the new admin-only `agencies.html` tool. One row per
-- `home_health_agencies.id` capturing what the user previously
-- maintained in `HH RATINGS.xlsx`:
--   * Per-discipline contract rates (OT/PT/ST × eval/assistant or other)
--   * 1–5 payment + communication ratings
--   * Contract metadata (location, start year, active flag)
--   * Payment workflow (preferred method, sent via, collections contact)
--   * Free-text notes
--
-- Sister table to `home_health_agencies` joined via agency_id (FK ON
-- DELETE CASCADE). Unique on agency_id for v1 — when contract history
-- becomes a thing, drop the unique index and add
-- effective_from/effective_to columns; the rest of the schema is
-- forward-compatible.
--
-- RLS: admin-only read + write (matches Finance posture). Two RPCs
-- run SECURITY DEFINER:
--   * list_agency_contracts() — LEFT JOIN so all agencies appear
--     even when they have no contract row yet (UI shows "—").
--   * upsert_agency_contracts(rows JSONB) — bulk import; matches
--     inbound names to home_health_agencies.name via the same
--     normalize_agency_name() helper the matcher uses for read-side
--     lookups. Returns matched count + unmatched name list so the
--     UI can render "M of N matched" without a second round-trip.
--
-- Idempotent — safe to re-run.
-- Run after: 01_phase1_enable_rls.sql (depends on user_roles + RLS infra).

BEGIN;

-- ── 1. Name-normalization helper (used by RPC + future matchers) ──
-- Lowercases, strips common business suffixes (inc/llc/ltd/corp), drops
-- punctuation, collapses whitespace. Same shape as the JS-side
-- normalizer in roster-review.html (clinician name → clinician_v2),
-- adapted for agency names which use Inc/LLC/etc instead of clinical
-- credential codes.
CREATE OR REPLACE FUNCTION public.normalize_agency_name(name TEXT)
RETURNS TEXT
LANGUAGE sql IMMUTABLE AS $$
  SELECT NULLIF(
    TRIM(
      REGEXP_REPLACE(
        REGEXP_REPLACE(
          REGEXP_REPLACE(
            LOWER(COALESCE(name, '')),
            '\.|,|''|"', '', 'g'                                    -- drop . , ' "
          ),
          '\m(inc|incorporated|llc|ltd|corp|corporation|co|company|pc|p\.c\.|services|service)\M', '', 'g'
        ),
        '\s+', ' ', 'g'                                              -- collapse whitespace
      )
    ),
    ''
  );
$$;

-- ── 2. Contracts table ────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.home_health_agency_contracts (
  id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  agency_id    TEXT NOT NULL REFERENCES public.home_health_agencies(id) ON DELETE CASCADE,

  -- Per-discipline rates (NUMERIC supports half-dollar amounts;
  -- column codes preserved in comments so we can round-trip back
  -- to the XLSX shape if needed)
  rate_ot_eval         NUMERIC,  -- OTF
  rate_ot_assistant    NUMERIC,  -- OTFA
  rate_pt_eval         NUMERIC,  -- PTF
  rate_pt_assistant    NUMERIC,  -- PTFA
  rate_st_eval         NUMERIC,  -- STE
  rate_st_other        NUMERIC,  -- STEO (recert / DC per user's source)

  -- 1–5 ratings (5 = best). NULL allowed for "not yet rated".
  rating_payment       SMALLINT,
  rating_communication SMALLINT,

  -- Contract metadata
  contract_location    TEXT,     -- "IN QB", "Drive Location", etc.
  is_active            BOOLEAN NOT NULL DEFAULT TRUE,
  contract_start_year  SMALLINT, -- spreadsheet uses bare year (2025, 2018)

  -- Payment workflow
  preferred_payment_method TEXT, -- "Zelle/DD", "Check Mail", "QB", ...
  sent_via                 TEXT, -- "Fax", "QB", "Email", ...
  collections_contact      TEXT, -- name + title

  -- Free text
  notes        TEXT,

  -- Audit
  created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_by   UUID REFERENCES auth.users(id)
);

-- Constraints split out of CREATE TABLE so re-runs don't double-add.
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'hhac_rating_payment_range') THEN
    ALTER TABLE public.home_health_agency_contracts
      ADD CONSTRAINT hhac_rating_payment_range
      CHECK (rating_payment IS NULL OR rating_payment BETWEEN 1 AND 5);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'hhac_rating_communication_range') THEN
    ALTER TABLE public.home_health_agency_contracts
      ADD CONSTRAINT hhac_rating_communication_range
      CHECK (rating_communication IS NULL OR rating_communication BETWEEN 1 AND 5);
  END IF;
END $$;

CREATE UNIQUE INDEX IF NOT EXISTS hhac_agency_id_uniq
  ON public.home_health_agency_contracts (agency_id);

CREATE INDEX IF NOT EXISTS hhac_active_idx
  ON public.home_health_agency_contracts (is_active);

-- ── 3. RLS — admin-only across the board (matches Finance) ────────
ALTER TABLE public.home_health_agency_contracts ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "hhac_admin_read"  ON public.home_health_agency_contracts;
DROP POLICY IF EXISTS "hhac_admin_write" ON public.home_health_agency_contracts;

CREATE POLICY "hhac_admin_read" ON public.home_health_agency_contracts
  FOR SELECT TO authenticated
  USING (EXISTS (SELECT 1 FROM public.user_roles ur
                 WHERE ur.user_id = auth.uid() AND ur.role = 'admin'));

CREATE POLICY "hhac_admin_write" ON public.home_health_agency_contracts
  FOR ALL TO authenticated
  USING      (EXISTS (SELECT 1 FROM public.user_roles ur
                      WHERE ur.user_id = auth.uid() AND ur.role = 'admin'))
  WITH CHECK (EXISTS (SELECT 1 FROM public.user_roles ur
                      WHERE ur.user_id = auth.uid() AND ur.role = 'admin'));

-- updated_at touch trigger
CREATE OR REPLACE FUNCTION public.hhac_touch_updated_at()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  NEW.updated_at := NOW();
  IF NEW.updated_by IS NULL THEN
    NEW.updated_by := auth.uid();
  END IF;
  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS hhac_touch_updated_at_trg ON public.home_health_agency_contracts;
CREATE TRIGGER hhac_touch_updated_at_trg
  BEFORE INSERT OR UPDATE ON public.home_health_agency_contracts
  FOR EACH ROW EXECUTE FUNCTION public.hhac_touch_updated_at();

-- ── 4. RPC: list_agency_contracts() ───────────────────────────────
-- Returns every agency (LEFT JOIN contracts) so the table page can
-- show all rows with "—" placeholders where no contract exists yet.
-- Admin gate inside the function — RLS would also block but the
-- explicit error gives a cleaner client-side message.
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
  updated_at             TIMESTAMPTZ
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
      c.notes, c.updated_at
    FROM home_health_agencies a
    LEFT JOIN home_health_agency_contracts c ON c.agency_id = a.id
    ORDER BY a.name NULLS LAST;
END $$;

REVOKE ALL ON FUNCTION public.list_agency_contracts() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.list_agency_contracts() TO authenticated;

-- ── 5. RPC: upsert_agency_contracts(rows JSONB) ───────────────────
-- Bulk import path. Inbound shape (one object per agency):
--   {
--     "agency_name": "...",            -- required for matching
--     "agency_id":   "..." (optional)  -- if user manually picked unmatch resolution
--     "rate_ot_eval": 90, ...,
--     "rating_payment": 3, "rating_communication": 4,
--     "contract_location": "...", "is_active": true,
--     "contract_start_year": 2025,
--     "preferred_payment_method": "...", "sent_via": "...",
--     "collections_contact": "...", "notes": "..."
--   }
--
-- Matching strategy:
--   1. If agency_id is provided → use it directly (manual resolution).
--   2. Else normalize agency_name and look up against
--      normalize_agency_name(home_health_agencies.name).
--   3. Unmatched rows are returned in the unmatched[] array — UI
--      surfaces them for manual resolution.
--
-- Returns: { matched: INT, unmatched: [{name: TEXT}] }.
CREATE OR REPLACE FUNCTION public.upsert_agency_contracts(rows JSONB)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  matched_count INT := 0;
  unmatched_arr JSONB := '[]'::JSONB;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM user_roles ur
                 WHERE ur.user_id = auth.uid() AND ur.role = 'admin') THEN
    RAISE EXCEPTION 'Only admin may upsert agency contracts';
  END IF;

  WITH src AS (
    SELECT
      x.agency_name,
      x.agency_id,
      x.rate_ot_eval, x.rate_ot_assistant,
      x.rate_pt_eval, x.rate_pt_assistant,
      x.rate_st_eval, x.rate_st_other,
      x.rating_payment, x.rating_communication,
      x.contract_location, x.is_active, x.contract_start_year,
      x.preferred_payment_method, x.sent_via, x.collections_contact,
      x.notes
    FROM jsonb_to_recordset(rows) AS x(
      agency_name              TEXT,
      agency_id                TEXT,
      rate_ot_eval             NUMERIC,
      rate_ot_assistant        NUMERIC,
      rate_pt_eval             NUMERIC,
      rate_pt_assistant        NUMERIC,
      rate_st_eval             NUMERIC,
      rate_st_other            NUMERIC,
      rating_payment           SMALLINT,
      rating_communication     SMALLINT,
      contract_location        TEXT,
      is_active                BOOLEAN,
      contract_start_year      SMALLINT,
      preferred_payment_method TEXT,
      sent_via                 TEXT,
      collections_contact      TEXT,
      notes                    TEXT
    )
  ),
  resolved AS (
    SELECT
      COALESCE(
        s.agency_id,                              -- 1. manual override wins
        (SELECT a.id FROM home_health_agencies a
          WHERE normalize_agency_name(a.name) = normalize_agency_name(s.agency_name)
          LIMIT 1)                                -- 2. normalized match
      ) AS agency_id,
      s.*
    FROM src s
  ),
  to_upsert AS (
    SELECT * FROM resolved WHERE agency_id IS NOT NULL
  ),
  ins AS (
    INSERT INTO home_health_agency_contracts (
      agency_id,
      rate_ot_eval, rate_ot_assistant,
      rate_pt_eval, rate_pt_assistant,
      rate_st_eval, rate_st_other,
      rating_payment, rating_communication,
      contract_location, is_active, contract_start_year,
      preferred_payment_method, sent_via, collections_contact,
      notes
    )
    SELECT
      agency_id,
      rate_ot_eval, rate_ot_assistant,
      rate_pt_eval, rate_pt_assistant,
      rate_st_eval, rate_st_other,
      rating_payment, rating_communication,
      contract_location, COALESCE(is_active, TRUE), contract_start_year,
      preferred_payment_method, sent_via, collections_contact,
      notes
    FROM to_upsert
    ON CONFLICT (agency_id) DO UPDATE SET
      rate_ot_eval             = COALESCE(EXCLUDED.rate_ot_eval,             home_health_agency_contracts.rate_ot_eval),
      rate_ot_assistant        = COALESCE(EXCLUDED.rate_ot_assistant,        home_health_agency_contracts.rate_ot_assistant),
      rate_pt_eval             = COALESCE(EXCLUDED.rate_pt_eval,             home_health_agency_contracts.rate_pt_eval),
      rate_pt_assistant        = COALESCE(EXCLUDED.rate_pt_assistant,        home_health_agency_contracts.rate_pt_assistant),
      rate_st_eval             = COALESCE(EXCLUDED.rate_st_eval,             home_health_agency_contracts.rate_st_eval),
      rate_st_other            = COALESCE(EXCLUDED.rate_st_other,            home_health_agency_contracts.rate_st_other),
      rating_payment           = COALESCE(EXCLUDED.rating_payment,           home_health_agency_contracts.rating_payment),
      rating_communication     = COALESCE(EXCLUDED.rating_communication,     home_health_agency_contracts.rating_communication),
      contract_location        = COALESCE(EXCLUDED.contract_location,        home_health_agency_contracts.contract_location),
      is_active                = EXCLUDED.is_active,
      contract_start_year      = COALESCE(EXCLUDED.contract_start_year,      home_health_agency_contracts.contract_start_year),
      preferred_payment_method = COALESCE(EXCLUDED.preferred_payment_method, home_health_agency_contracts.preferred_payment_method),
      sent_via                 = COALESCE(EXCLUDED.sent_via,                 home_health_agency_contracts.sent_via),
      collections_contact      = COALESCE(EXCLUDED.collections_contact,      home_health_agency_contracts.collections_contact),
      notes                    = COALESCE(EXCLUDED.notes,                    home_health_agency_contracts.notes),
      updated_at               = NOW(),
      updated_by               = auth.uid()
    RETURNING 1
  )
  SELECT count(*) INTO matched_count FROM ins;

  -- Build the unmatched list — re-parse rows since the prior CTE `src`
  -- is out of scope after the WITH chain above completed.
  SELECT COALESCE(jsonb_agg(jsonb_build_object('name', x.agency_name)), '[]'::JSONB)
    INTO unmatched_arr
    FROM jsonb_to_recordset(rows) AS x(agency_name TEXT, agency_id TEXT)
    WHERE NOT EXISTS (
      SELECT 1 FROM home_health_agencies a
      WHERE a.id = COALESCE(
        x.agency_id,
        (SELECT a2.id FROM home_health_agencies a2
          WHERE normalize_agency_name(a2.name) = normalize_agency_name(x.agency_name)
          LIMIT 1)
      )
    );

  RETURN jsonb_build_object(
    'matched',   matched_count,
    'unmatched', unmatched_arr
  );
END $$;

REVOKE ALL ON FUNCTION public.upsert_agency_contracts(JSONB) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.upsert_agency_contracts(JSONB) TO authenticated;

-- ── 6. RPC: update_agency_contract(...) ───────────────────────────
-- Single-row field-level patch used by the inline editors in
-- agencies.html. Auto-creates the contract row on first edit so the
-- UI doesn't need separate insert/update code paths. Pass NULL to
-- clear a field; omit a field (don't include the key) to leave it
-- unchanged — handled by the COALESCE pattern via separate
-- "field name" + "value" parameters keeps the surface tiny.
CREATE OR REPLACE FUNCTION public.update_agency_contract(
  p_agency_id TEXT,
  p_field     TEXT,
  p_value     JSONB
)
RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  allowed_fields TEXT[] := ARRAY[
    'rate_ot_eval','rate_ot_assistant',
    'rate_pt_eval','rate_pt_assistant',
    'rate_st_eval','rate_st_other',
    'rating_payment','rating_communication',
    'contract_location','is_active','contract_start_year',
    'preferred_payment_method','sent_via','collections_contact',
    'notes'
  ];
  col_type       TEXT;
  scalar_text    TEXT;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM user_roles ur
                 WHERE ur.user_id = auth.uid() AND ur.role = 'admin') THEN
    RAISE EXCEPTION 'Only admin may edit agency contracts';
  END IF;

  IF NOT (p_field = ANY(allowed_fields)) THEN
    RAISE EXCEPTION 'Field % is not editable', p_field;
  END IF;

  -- Ensure a contract row exists.
  INSERT INTO home_health_agency_contracts (agency_id)
  VALUES (p_agency_id)
  ON CONFLICT (agency_id) DO NOTHING;

  -- Pick the SQL type to cast into based on the whitelisted field.
  col_type := CASE
    WHEN p_field IN ('rate_ot_eval','rate_ot_assistant',
                     'rate_pt_eval','rate_pt_assistant',
                     'rate_st_eval','rate_st_other')                    THEN 'NUMERIC'
    WHEN p_field IN ('rating_payment','rating_communication',
                     'contract_start_year')                             THEN 'SMALLINT'
    WHEN p_field = 'is_active'                                          THEN 'BOOLEAN'
    ELSE                                                                     'TEXT'
  END;

  -- Extract the JSONB scalar into TEXT, treating JSON null + missing
  -- value as SQL NULL so the typed cast below produces NULL cleanly.
  IF p_value IS NULL OR jsonb_typeof(p_value) = 'null' THEN
    scalar_text := NULL;
  ELSE
    scalar_text := p_value #>> '{}';
  END IF;

  -- Dynamic UPDATE — both column identifier and target type are
  -- whitelisted (safe from injection); scalar_text is bound via USING.
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

REVOKE ALL ON FUNCTION public.update_agency_contract(TEXT, TEXT, JSONB) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.update_agency_contract(TEXT, TEXT, JSONB) TO authenticated;

COMMIT;

NOTIFY pgrst, 'reload schema';
