-- Clinician Med B — Strata-name → TB-clinician alias memory
-- =====================================================================
-- Strata's productivity PDF sometimes uses slightly different spellings
-- of a clinician's name than TB's Prepare-payroll file. For example,
-- Strata might emit "Gina M Pelehac (OT)" while TB lists her as
-- "Gina Pelehac OT" — so the lookup_key match fails and Med B goes
-- unmatched.
--
-- This table remembers admin-curated mappings: "this normalized Strata
-- name = this TB clinician_lookup_key". On every subsequent import,
-- the parser hits this table BEFORE declaring a row unmatched.
--
-- Pattern mirrors `bank_match_payer_routing` (migration 32) — same
-- learn-as-you-go memory shape with hit_count + last_seen_at.
--
-- Admin-only RLS across the board (matches Finance posture). Idempotent.

BEGIN;

-- ── 1. Table ──────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.clinician_medb_name_aliases (
  id                      UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  -- normalized form of the name as it appears in Strata's PDF
  -- (same cprClinLookupKey shape: lowercase, trailing discipline suffix stripped)
  strata_name_normalized  TEXT NOT NULL UNIQUE,
  -- last-seen display form (e.g. "Gina M Pelehac (OT)") for the alias-list UI
  strata_name_display     TEXT NOT NULL,
  -- normalized lookup_key into the TB clinician name (same shape)
  tb_lookup_key           TEXT NOT NULL,
  -- last-seen display form of the TB clinician (e.g. "Gina Pelehac OT")
  tb_display              TEXT NOT NULL,
  hit_count               INTEGER NOT NULL DEFAULT 1,
  first_seen_at           TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  last_seen_at            TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  last_set_by             UUID REFERENCES auth.users(id)
);

CREATE INDEX IF NOT EXISTS cmna_tb_key_idx
  ON public.clinician_medb_name_aliases (tb_lookup_key);
CREATE INDEX IF NOT EXISTS cmna_last_seen_idx
  ON public.clinician_medb_name_aliases (last_seen_at DESC);

-- ── 2. RLS — admin only ──────────────────────────────────────────
ALTER TABLE public.clinician_medb_name_aliases ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "cmna_admin_read"  ON public.clinician_medb_name_aliases;
DROP POLICY IF EXISTS "cmna_admin_write" ON public.clinician_medb_name_aliases;

CREATE POLICY "cmna_admin_read" ON public.clinician_medb_name_aliases
  FOR SELECT TO authenticated
  USING (EXISTS (SELECT 1 FROM public.user_roles ur
                 WHERE ur.user_id = auth.uid() AND ur.role = 'admin'));

CREATE POLICY "cmna_admin_write" ON public.clinician_medb_name_aliases
  FOR ALL TO authenticated
  USING      (EXISTS (SELECT 1 FROM public.user_roles ur
                      WHERE ur.user_id = auth.uid() AND ur.role = 'admin'))
  WITH CHECK (EXISTS (SELECT 1 FROM public.user_roles ur
                      WHERE ur.user_id = auth.uid() AND ur.role = 'admin'));

-- ── 3. RPC: list_clinician_medb_name_aliases ─────────────────────
-- Bulk read — entire table at once. The client builds a Map<strata_norm, tb_key>
-- on import to pre-resolve names before declaring them unmatched. Volume
-- is tiny (one row per unique-spelling clinician, max a few hundred forever)
-- so no pagination needed.
CREATE OR REPLACE FUNCTION public.list_clinician_medb_name_aliases()
RETURNS TABLE (
  id                      UUID,
  strata_name_normalized  TEXT,
  strata_name_display     TEXT,
  tb_lookup_key           TEXT,
  tb_display              TEXT,
  hit_count               INTEGER,
  first_seen_at           TIMESTAMPTZ,
  last_seen_at            TIMESTAMPTZ,
  last_set_by_email       TEXT
)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM user_roles ur
                 WHERE ur.user_id = auth.uid() AND ur.role = 'admin') THEN
    RAISE EXCEPTION 'Only admin may list Med B name aliases';
  END IF;

  RETURN QUERY
    SELECT
      a.id,
      a.strata_name_normalized::TEXT,
      a.strata_name_display::TEXT,
      a.tb_lookup_key::TEXT,
      a.tb_display::TEXT,
      a.hit_count,
      a.first_seen_at,
      a.last_seen_at,
      (SELECT u.email::TEXT FROM auth.users u WHERE u.id = a.last_set_by) AS last_set_by_email
    FROM clinician_medb_name_aliases a
    ORDER BY a.last_seen_at DESC;
END $$;

REVOKE ALL ON FUNCTION public.list_clinician_medb_name_aliases() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.list_clinician_medb_name_aliases() TO authenticated;

-- ── 4. RPC: upsert_clinician_medb_name_aliases (BULK) ────────────
-- Bulk upsert called when the audit saves with newly-resolved aliases.
-- Input shape (p_rows JSONB array):
--   [
--     { "strata_normalized": "gina m pelehac",
--       "strata_display":    "Gina M Pelehac (OT)",
--       "tb_lookup_key":     "gina pelehac",
--       "tb_display":        "Gina Pelehac OT" },
--     ...
--   ]
-- On conflict (same strata_normalized): bumps hit_count + updates last_seen_at
-- + actor + display fields. The tb_lookup_key is also updated so if the
-- admin reassigns an alias, the new mapping wins.
CREATE OR REPLACE FUNCTION public.upsert_clinician_medb_name_aliases(p_rows JSONB)
RETURNS INTEGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  n         INT := 0;
  rec       JSONB;
  sn        TEXT;
  sd        TEXT;
  tk        TEXT;
  td        TEXT;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM user_roles ur
                 WHERE ur.user_id = auth.uid() AND ur.role = 'admin') THEN
    RAISE EXCEPTION 'Only admin may upsert Med B name aliases';
  END IF;
  IF p_rows IS NULL OR jsonb_typeof(p_rows) <> 'array' THEN
    RAISE EXCEPTION 'p_rows must be a JSONB array';
  END IF;

  FOR rec IN SELECT * FROM jsonb_array_elements(p_rows) LOOP
    sn := LOWER(TRIM(COALESCE(rec ->> 'strata_normalized', '')));
    sd := TRIM(COALESCE(rec ->> 'strata_display', ''));
    tk := LOWER(TRIM(COALESCE(rec ->> 'tb_lookup_key', '')));
    td := TRIM(COALESCE(rec ->> 'tb_display', ''));

    IF sn = '' OR tk = '' OR sd = '' OR td = '' THEN
      CONTINUE;   -- skip rows missing any required field
    END IF;

    INSERT INTO clinician_medb_name_aliases
      (strata_name_normalized, strata_name_display, tb_lookup_key, tb_display, last_set_by)
    VALUES (sn, sd, tk, td, auth.uid())
    ON CONFLICT (strata_name_normalized) DO UPDATE
      SET strata_name_display = EXCLUDED.strata_name_display,
          tb_lookup_key       = EXCLUDED.tb_lookup_key,
          tb_display          = EXCLUDED.tb_display,
          hit_count           = clinician_medb_name_aliases.hit_count + 1,
          last_seen_at        = NOW(),
          last_set_by         = auth.uid();
    n := n + 1;
  END LOOP;

  RETURN n;
END $$;

REVOKE ALL ON FUNCTION public.upsert_clinician_medb_name_aliases(JSONB) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.upsert_clinician_medb_name_aliases(JSONB) TO authenticated;

-- ── 5. RPC: forget_clinician_medb_name_alias ─────────────────────
-- Hard delete by Strata's normalized name. Used when admin mis-matched
-- (e.g., accidentally mapped Gina to the wrong TB clinician) and wants
-- to re-teach the mapping fresh.
CREATE OR REPLACE FUNCTION public.forget_clinician_medb_name_alias(p_strata_normalized TEXT)
RETURNS INTEGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE n INT;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM user_roles ur
                 WHERE ur.user_id = auth.uid() AND ur.role = 'admin') THEN
    RAISE EXCEPTION 'Only admin may forget Med B name aliases';
  END IF;

  DELETE FROM clinician_medb_name_aliases
  WHERE strata_name_normalized = LOWER(TRIM(p_strata_normalized));
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END $$;

REVOKE ALL ON FUNCTION public.forget_clinician_medb_name_alias(TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.forget_clinician_medb_name_alias(TEXT) TO authenticated;

COMMIT;

NOTIFY pgrst, 'reload schema';
