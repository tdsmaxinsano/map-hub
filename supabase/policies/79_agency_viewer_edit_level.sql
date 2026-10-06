-- ════════════════════════════════════════════════════════════════════
-- 79 · Agency grants — add an EDIT level (requires migration 78)
--
-- agency_viewers gains access ('view' | 'edit'). Both levels can open
-- the page and read everything (the 78 read-RPC checks already accept
-- any grant row). 'edit' additionally unlocks the INLINE editors by
-- widening update_agency_contract to admin OR edit-grantee.
-- Imports (upsert_agency_contracts / import_agency_price_list) stay
-- strictly admin-only. Grants are managed from the page's 👁 Viewers
-- modal (admin-only, RLS from migration 78). Idempotent.
-- ════════════════════════════════════════════════════════════════════
BEGIN;

ALTER TABLE public.agency_viewers
  ADD COLUMN IF NOT EXISTS access TEXT NOT NULL DEFAULT 'view';
ALTER TABLE public.agency_viewers
  DROP CONSTRAINT IF EXISTS agency_viewers_access_check;
ALTER TABLE public.agency_viewers
  ADD CONSTRAINT agency_viewers_access_check CHECK (access IN ('view', 'edit'));

-- ── update_agency_contract: admin OR edit-grantee ────────────────────
-- Body identical to migration 30; only the access check changes.
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

REVOKE ALL ON FUNCTION public.update_agency_contract(TEXT, TEXT, JSONB) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.update_agency_contract(TEXT, TEXT, JSONB) TO authenticated, service_role;

NOTIFY pgrst, 'reload schema';

COMMIT;
