-- Bank Match — Learned payer-routing memory
-- =====================================================================
-- Backs a small learn-as-you-go feature in the 📷 Scan a patient check
-- flow. Every time the user clicks "Add to batch" with a chosen GL,
-- we save (normalized_payer_name → gl_account) here. Next time the
-- same payer name shows up on a scan, the tool auto-fills that GL
-- before the keyword-based smart default kicks in.
--
-- Why this matters: the static CARRIER_KEYWORDS list in finance.html
-- can't possibly cover every carrier name on the planet (Medical
-- Mutual, smaller TPAs, regional plans, etc.). Instead of forcing
-- the user to manually re-correct the GL on every scan of a missed
-- carrier, we learn the routing from their first correction.
--
-- Lookup precedence on a scan:
--   1. learned-routing match (this table)           ← winner
--   2. CARRIER_KEYWORDS substring match (client-side)
--   3. Accounts Receivable (default patient co-pay)
--
-- Admin-only RLS matching Finance posture. Idempotent.

BEGIN;

-- ── 1. Table ──────────────────────────────────────────────────────
-- One row per unique normalized payer name. payer_display keeps the
-- last-seen display form (Title Case-ish) for an eventual admin UI.
-- hit_count + last_seen_at help future ranking / pruning.
CREATE TABLE IF NOT EXISTS public.bank_match_payer_routing (
  id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  payer_normalized  TEXT NOT NULL UNIQUE,
  payer_display     TEXT NOT NULL,
  gl_account        TEXT NOT NULL,
  hit_count         INTEGER NOT NULL DEFAULT 1,
  first_seen_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  last_seen_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  last_set_by       UUID REFERENCES auth.users(id)
);

CREATE INDEX IF NOT EXISTS bmpr_last_seen_idx
  ON public.bank_match_payer_routing (last_seen_at DESC);

-- ── 2. RLS — admin only ──────────────────────────────────────────
ALTER TABLE public.bank_match_payer_routing ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "bmpr_admin_read"  ON public.bank_match_payer_routing;
DROP POLICY IF EXISTS "bmpr_admin_write" ON public.bank_match_payer_routing;

CREATE POLICY "bmpr_admin_read" ON public.bank_match_payer_routing
  FOR SELECT TO authenticated
  USING (EXISTS (SELECT 1 FROM public.user_roles ur
                 WHERE ur.user_id = auth.uid() AND ur.role = 'admin'));

CREATE POLICY "bmpr_admin_write" ON public.bank_match_payer_routing
  FOR ALL TO authenticated
  USING      (EXISTS (SELECT 1 FROM public.user_roles ur
                      WHERE ur.user_id = auth.uid() AND ur.role = 'admin'))
  WITH CHECK (EXISTS (SELECT 1 FROM public.user_roles ur
                      WHERE ur.user_id = auth.uid() AND ur.role = 'admin'));

-- ── 3. Normalizer (IMMUTABLE so it can be used in indexes/expressions) ──
-- Lower-cases, collapses whitespace, drops common business suffixes
-- and punctuation. Same shape as the agency-name normalizer from
-- migration 30, adapted for insurance carriers.
CREATE OR REPLACE FUNCTION public.normalize_payer_name(name TEXT)
RETURNS TEXT
LANGUAGE sql IMMUTABLE AS $$
  SELECT NULLIF(
    TRIM(
      REGEXP_REPLACE(
        REGEXP_REPLACE(
          REGEXP_REPLACE(
            LOWER(COALESCE(name, '')),
            '\.|,|''|"|/|\\|#|\(|\)', '', 'g'             -- drop punct
          ),
          '\m(inc|incorporated|llc|ltd|corp|corporation|co|company|of\s+ohio|of\s+illinois|of\s+california|hmo|ppo|plan)\M', '', 'g'
        ),
        '\s+', ' ', 'g'                                    -- collapse ws
      )
    ),
    ''
  );
$$;

-- ── 4. RPC: lookup_payer_routing ──────────────────────────────────
-- Returns the saved GL for a payer name, or NULL if no learned
-- routing exists. Side-effect-free read.
CREATE OR REPLACE FUNCTION public.lookup_payer_routing(p_payer TEXT)
RETURNS TEXT
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  result TEXT;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM user_roles ur
                 WHERE ur.user_id = auth.uid() AND ur.role = 'admin') THEN
    RAISE EXCEPTION 'Only admin may query payer routing';
  END IF;

  SELECT gl_account INTO result
  FROM bank_match_payer_routing
  WHERE payer_normalized = normalize_payer_name(p_payer)
  LIMIT 1;

  RETURN result;
END $$;

REVOKE ALL ON FUNCTION public.lookup_payer_routing(TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.lookup_payer_routing(TEXT) TO authenticated;

-- ── 5. RPC: remember_payer_routing ────────────────────────────────
-- Upsert: insert new row OR bump hit_count + update gl_account +
-- stamp last_seen_at + last_set_by. Returns the row id.
CREATE OR REPLACE FUNCTION public.remember_payer_routing(
  p_payer TEXT,
  p_gl    TEXT
)
RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  norm   TEXT;
  out_id UUID;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM user_roles ur
                 WHERE ur.user_id = auth.uid() AND ur.role = 'admin') THEN
    RAISE EXCEPTION 'Only admin may remember payer routing';
  END IF;
  IF p_payer IS NULL OR TRIM(p_payer) = '' THEN
    RAISE EXCEPTION 'payer required';
  END IF;
  IF p_gl IS NULL OR TRIM(p_gl) = '' THEN
    RAISE EXCEPTION 'gl required';
  END IF;

  norm := normalize_payer_name(p_payer);
  IF norm IS NULL THEN
    RAISE EXCEPTION 'normalized payer is empty';
  END IF;

  INSERT INTO bank_match_payer_routing (
    payer_normalized, payer_display, gl_account, last_set_by
  )
  VALUES (norm, TRIM(p_payer), TRIM(p_gl), auth.uid())
  ON CONFLICT (payer_normalized) DO UPDATE
    SET gl_account    = EXCLUDED.gl_account,
        payer_display = EXCLUDED.payer_display,
        hit_count     = bank_match_payer_routing.hit_count + 1,
        last_seen_at  = NOW(),
        last_set_by   = auth.uid()
  RETURNING id INTO out_id;

  RETURN out_id;
END $$;

REVOKE ALL ON FUNCTION public.remember_payer_routing(TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.remember_payer_routing(TEXT, TEXT) TO authenticated;

-- ── 6. RPC: forget_payer_routing ──────────────────────────────────
-- Hard delete of a learned mapping. Used when admin wants to wipe
-- a bad routing (e.g., they accidentally saved a typo). Future
-- admin UI will surface this as a per-row 🗑 button.
CREATE OR REPLACE FUNCTION public.forget_payer_routing(p_payer TEXT)
RETURNS INTEGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  n INT;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM user_roles ur
                 WHERE ur.user_id = auth.uid() AND ur.role = 'admin') THEN
    RAISE EXCEPTION 'Only admin may forget payer routing';
  END IF;

  DELETE FROM bank_match_payer_routing
  WHERE payer_normalized = normalize_payer_name(p_payer);
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END $$;

REVOKE ALL ON FUNCTION public.forget_payer_routing(TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.forget_payer_routing(TEXT) TO authenticated;

-- ── 7. (future) RPC: list_payer_routings ──────────────────────────
-- Surfaces all learned routings for an eventual admin UI. NOT used
-- by today's frontend but ships with the migration so it's already
-- there when we wire the UI later.
CREATE OR REPLACE FUNCTION public.list_payer_routings(p_limit INTEGER DEFAULT 200)
RETURNS TABLE (
  id              UUID,
  payer_display   TEXT,
  payer_normalized TEXT,
  gl_account      TEXT,
  hit_count       INTEGER,
  first_seen_at   TIMESTAMPTZ,
  last_seen_at    TIMESTAMPTZ,
  last_set_by_email TEXT
)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM user_roles ur
                 WHERE ur.user_id = auth.uid() AND ur.role = 'admin') THEN
    RAISE EXCEPTION 'Only admin may list payer routings';
  END IF;

  RETURN QUERY
    SELECT
      r.id,
      r.payer_display::TEXT,
      r.payer_normalized::TEXT,
      r.gl_account::TEXT,
      r.hit_count,
      r.first_seen_at,
      r.last_seen_at,
      (SELECT u.email::TEXT FROM auth.users u WHERE u.id = r.last_set_by) AS last_set_by_email
    FROM bank_match_payer_routing r
    ORDER BY r.last_seen_at DESC
    LIMIT COALESCE(p_limit, 200);
END $$;

REVOKE ALL ON FUNCTION public.list_payer_routings(INTEGER) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.list_payer_routings(INTEGER) TO authenticated;

COMMIT;

NOTIFY pgrst, 'reload schema';
