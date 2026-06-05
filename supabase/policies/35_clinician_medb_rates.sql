-- Clinician Med B per-visit Rate — learn-as-you-go memory
-- =====================================================================
-- Stores each clinician's effective per-visit rate (in dollars) so the
-- Strata Med B parser can multiply Strata visits × rate to land Med B
-- amounts without the user having to type a rate per period.
--
-- Strata exports a productivity PDF that gives us visits per clinician
-- BUT NOT the rate (rates aren't configured in Strata). TB's Prepare-
-- payroll Excel DOES carry a per-visit Pay value (e.g. $55 for Basma
-- Rafael PT's PTDC visits). So we derive each clinician's rate from
-- their TB visit history and remember it for next time.
--
-- Lookup precedence on a Strata Med B import (client-side):
--   1. learned-rate hit (this table)            ← wins
--   2. discipline-aware derivation from current-period TB visits:
--        • assistants (PTA/OTA/STA/COTA/SLPA/LPN/CNA/HHA)
--          → MODE of TB Pay values (assistants only do follow-ups)
--        • supervisors (PT/OT/ST/SLP/OTR/RN/...)
--          → LOWEST non-zero distinct TB Pay value (drop the eval rate)
--   3. NULL → render as "⚠ rate unknown" + Med B = $0
--
-- Also auto-refreshed on every TB import (regardless of whether a
-- Strata file is dropped) so memory stays current as standard rates
-- shift over time (e.g. $55 → $60 follow-up rate).
--
-- Admin-only RLS (matches Finance posture). Idempotent.

BEGIN;

-- ── 1. Table ──────────────────────────────────────────────────────
-- One row per unique normalized clinician name. clinician_lookup_key
-- uses the same key shape as finance.html's cprClinLookupKey (lowercase,
-- trailing-discipline-suffix stripped) so JS + SQL agree on the key.
CREATE TABLE IF NOT EXISTS public.clinician_medb_rates (
  id                     UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  clinician_lookup_key   TEXT NOT NULL UNIQUE,
  clinician_display      TEXT NOT NULL,
  discipline             TEXT,
  rate                   NUMERIC(8,2) NOT NULL CHECK (rate >= 0),
  source                 TEXT NOT NULL
                         CHECK (source IN (
                           'derived_assistant_mode',
                           'derived_supervisor_min',
                           'manual_override',
                           'memory_hit'
                         )),
  hit_count              INTEGER NOT NULL DEFAULT 1,
  first_seen_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  last_seen_at           TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  last_set_by            UUID REFERENCES auth.users(id)
);

CREATE INDEX IF NOT EXISTS cmr_last_seen_idx
  ON public.clinician_medb_rates (last_seen_at DESC);

-- ── 2. RLS — admin only ──────────────────────────────────────────
ALTER TABLE public.clinician_medb_rates ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "cmr_admin_read"  ON public.clinician_medb_rates;
DROP POLICY IF EXISTS "cmr_admin_write" ON public.clinician_medb_rates;

CREATE POLICY "cmr_admin_read" ON public.clinician_medb_rates
  FOR SELECT TO authenticated
  USING (EXISTS (SELECT 1 FROM public.user_roles ur
                 WHERE ur.user_id = auth.uid() AND ur.role = 'admin'));

CREATE POLICY "cmr_admin_write" ON public.clinician_medb_rates
  FOR ALL TO authenticated
  USING      (EXISTS (SELECT 1 FROM public.user_roles ur
                      WHERE ur.user_id = auth.uid() AND ur.role = 'admin'))
  WITH CHECK (EXISTS (SELECT 1 FROM public.user_roles ur
                      WHERE ur.user_id = auth.uid() AND ur.role = 'admin'));

-- ── 3. RPC: lookup_clinician_medb_rate ────────────────────────────
-- Single-row read by lookup_key. Returns NULL if no memory exists.
CREATE OR REPLACE FUNCTION public.lookup_clinician_medb_rate(p_lookup_key TEXT)
RETURNS NUMERIC
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE result NUMERIC;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM user_roles ur
                 WHERE ur.user_id = auth.uid() AND ur.role = 'admin') THEN
    RAISE EXCEPTION 'Only admin may query Med B rates';
  END IF;

  SELECT rate INTO result
  FROM clinician_medb_rates
  WHERE clinician_lookup_key = LOWER(TRIM(p_lookup_key))
  LIMIT 1;

  RETURN result;
END $$;

REVOKE ALL ON FUNCTION public.lookup_clinician_medb_rate(TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.lookup_clinician_medb_rate(TEXT) TO authenticated;

-- ── 4. RPC: upsert_clinician_medb_rates (BULK) ────────────────────
-- Used by the CPR flow at two moments: (1) every TB import refreshes
-- memory with freshly-derived rates so the cache stays current,
-- (2) every Strata Med B save persists any user-edited rates as
-- manual overrides.
--
-- Input shape (p_rows JSONB array):
--   [
--     { "lookup_key": "adam ouyang",
--       "display":    "Adam Ouyang",
--       "discipline": "PT",
--       "rate":       55.00,
--       "source":     "derived_supervisor_min" },
--     ...
--   ]
--
-- Conflict rule:
--   * If the existing row's source is 'manual_override' AND the incoming
--     source is NOT 'manual_override', PRESERVE the manual rate (a hand-
--     edited value should NOT be silently overwritten by a fresh derivation).
--     Only the hit_count + last_seen_at + display + discipline are bumped.
--   * Otherwise, overwrite rate + source + last_set_by; bump hit_count.
CREATE OR REPLACE FUNCTION public.upsert_clinician_medb_rates(p_rows JSONB)
RETURNS INTEGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  n           INT := 0;
  rec         JSONB;
  k           TEXT;
  display     TEXT;
  disc        TEXT;
  rate_in     NUMERIC;
  src         TEXT;
  existing    public.clinician_medb_rates;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM user_roles ur
                 WHERE ur.user_id = auth.uid() AND ur.role = 'admin') THEN
    RAISE EXCEPTION 'Only admin may upsert Med B rates';
  END IF;
  IF p_rows IS NULL OR jsonb_typeof(p_rows) <> 'array' THEN
    RAISE EXCEPTION 'p_rows must be a JSONB array';
  END IF;

  FOR rec IN SELECT * FROM jsonb_array_elements(p_rows) LOOP
    k       := LOWER(TRIM(COALESCE(rec ->> 'lookup_key', '')));
    display := TRIM(COALESCE(rec ->> 'display', ''));
    disc    := NULLIF(TRIM(COALESCE(rec ->> 'discipline', '')), '');
    rate_in := NULLIF(rec ->> 'rate', '')::NUMERIC;
    src     := COALESCE(rec ->> 'source', 'derived_supervisor_min');

    -- Skip junk rows: missing key, missing display, NULL rate, negative rate
    IF k = '' OR display = '' OR rate_in IS NULL OR rate_in < 0 THEN
      CONTINUE;
    END IF;
    -- Source has to be one of the allowed values (defensive)
    IF src NOT IN ('derived_assistant_mode', 'derived_supervisor_min',
                   'manual_override', 'memory_hit') THEN
      src := 'derived_supervisor_min';
    END IF;

    SELECT * INTO existing FROM clinician_medb_rates WHERE clinician_lookup_key = k;

    IF existing.id IS NULL THEN
      -- New row
      INSERT INTO clinician_medb_rates
        (clinician_lookup_key, clinician_display, discipline, rate, source, last_set_by)
      VALUES (k, display, disc, rate_in, src, auth.uid());
      n := n + 1;
    ELSIF existing.source = 'manual_override' AND src <> 'manual_override' THEN
      -- Preserve manual override; just bump metadata
      UPDATE clinician_medb_rates SET
        clinician_display = display,
        discipline        = COALESCE(disc, discipline),
        hit_count         = hit_count + 1,
        last_seen_at      = NOW()
      WHERE id = existing.id;
      n := n + 1;
    ELSE
      -- Overwrite rate + source + actor
      UPDATE clinician_medb_rates SET
        clinician_display = display,
        discipline        = COALESCE(disc, discipline),
        rate              = rate_in,
        source            = src,
        hit_count         = hit_count + 1,
        last_seen_at      = NOW(),
        last_set_by       = auth.uid()
      WHERE id = existing.id;
      n := n + 1;
    END IF;
  END LOOP;

  RETURN n;
END $$;

REVOKE ALL ON FUNCTION public.upsert_clinician_medb_rates(JSONB) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.upsert_clinician_medb_rates(JSONB) TO authenticated;

-- ── 5. RPC: list_clinician_medb_rates ─────────────────────────────
-- Returns the full table for an eventual admin-view UI. Sorted by
-- most-recently-seen so stale entries sink to the bottom.
CREATE OR REPLACE FUNCTION public.list_clinician_medb_rates()
RETURNS TABLE (
  id                   UUID,
  clinician_lookup_key TEXT,
  clinician_display    TEXT,
  discipline           TEXT,
  rate                 NUMERIC,
  source               TEXT,
  hit_count            INTEGER,
  first_seen_at        TIMESTAMPTZ,
  last_seen_at         TIMESTAMPTZ,
  last_set_by_email    TEXT
)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM user_roles ur
                 WHERE ur.user_id = auth.uid() AND ur.role = 'admin') THEN
    RAISE EXCEPTION 'Only admin may list Med B rates';
  END IF;

  RETURN QUERY
    SELECT
      r.id,
      r.clinician_lookup_key::TEXT,
      r.clinician_display::TEXT,
      r.discipline::TEXT,
      r.rate,
      r.source::TEXT,
      r.hit_count,
      r.first_seen_at,
      r.last_seen_at,
      (SELECT u.email::TEXT FROM auth.users u WHERE u.id = r.last_set_by) AS last_set_by_email
    FROM clinician_medb_rates r
    ORDER BY r.last_seen_at DESC;
END $$;

REVOKE ALL ON FUNCTION public.list_clinician_medb_rates() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.list_clinician_medb_rates() TO authenticated;

COMMIT;

NOTIFY pgrst, 'reload schema';
