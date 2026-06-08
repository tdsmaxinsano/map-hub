-- Clinician Med B — split PT/OT supervisor rates into Eval + Follow-up
-- =====================================================================
-- Background: PT and OT supervisors don't bill at a single per-visit
-- rate. They have TWO rates:
--   • Follow-up (PTF / OTF) — billed for regular treatment visits
--   • Eval     (PTE / OTE) — billed when the visit's CPT code is an
--     eval code (97161-97164 PT; 97165-97168 OT)
--
-- Assistants (PTA/OTA/etc.) don't bill evals → keep one rate (PTFA/OTFA).
-- ST + other supervisors: out of scope for Med B in this shop → keep
-- single-rate behavior.
--
-- This migration extends migration 35's clinician_medb_rates table with
-- an eval_rate column + updates the upsert/list RPCs to carry it. The
-- Strata PDF parser counts eval-coded visits per clinician; Med B
-- compute = eval_count × eval_rate + follow_up_count × rate (follow-up).
--
-- Idempotent + backward-compatible: pre-existing single-rate rows have
-- eval_rate = NULL and continue working (client-side computeMedbForClin
-- falls back to single-rate when eval_rate is NULL).

BEGIN;

-- ── 1. Add eval_rate column ───────────────────────────────────────
ALTER TABLE public.clinician_medb_rates
  ADD COLUMN IF NOT EXISTS eval_rate NUMERIC(8,2)
    CHECK (eval_rate IS NULL OR eval_rate >= 0);

COMMENT ON COLUMN public.clinician_medb_rates.rate IS
  'Follow-up (non-eval) per-visit rate. PTF for PT supervisors, PTFA for PT assistants, OTF/OTFA for OT.';
COMMENT ON COLUMN public.clinician_medb_rates.eval_rate IS
  'Eval per-visit rate. PTE for PT supervisors, OTE for OT supervisors. NULL for assistants (no evals) and out-of-scope disciplines.';

-- ── 2. Widen source CHECK constraint ──────────────────────────────
-- New source value 'derived_supervisor_split' marks rows whose rate +
-- eval_rate were BOTH derived from TB's per-visit pay column (lowest
-- non-zero distinct = follow-up, highest distinct = eval).
ALTER TABLE public.clinician_medb_rates
  DROP CONSTRAINT IF EXISTS clinician_medb_rates_source_check;
ALTER TABLE public.clinician_medb_rates
  ADD CONSTRAINT clinician_medb_rates_source_check
  CHECK (source IN (
    'derived_assistant_mode',
    'derived_supervisor_min',
    'derived_supervisor_split',
    'manual_override',
    'memory_hit'
  ));

-- ── 3. upsert_clinician_medb_rates — adds eval_rate support ───────
-- DROP-then-CREATE because the input shape grows a new optional field.
-- The conflict rule unchanged: manual_override rows are preserved
-- against subsequent fresh-derivation upserts.
DROP FUNCTION IF EXISTS public.upsert_clinician_medb_rates(JSONB);

CREATE OR REPLACE FUNCTION public.upsert_clinician_medb_rates(p_rows JSONB)
RETURNS INTEGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  n            INT := 0;
  rec          JSONB;
  k            TEXT;
  display      TEXT;
  disc         TEXT;
  rate_in      NUMERIC;
  eval_rate_in NUMERIC;
  src          TEXT;
  existing     public.clinician_medb_rates;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM user_roles ur
                 WHERE ur.user_id = auth.uid() AND ur.role = 'admin') THEN
    RAISE EXCEPTION 'Only admin may upsert Med B rates';
  END IF;
  IF p_rows IS NULL OR jsonb_typeof(p_rows) <> 'array' THEN
    RAISE EXCEPTION 'p_rows must be a JSONB array';
  END IF;

  FOR rec IN SELECT * FROM jsonb_array_elements(p_rows) LOOP
    k            := LOWER(TRIM(COALESCE(rec ->> 'lookup_key', '')));
    display      := TRIM(COALESCE(rec ->> 'display', ''));
    disc         := NULLIF(TRIM(COALESCE(rec ->> 'discipline', '')), '');
    rate_in      := NULLIF(rec ->> 'rate', '')::NUMERIC;
    eval_rate_in := NULLIF(rec ->> 'eval_rate', '')::NUMERIC;
    src          := COALESCE(rec ->> 'source', 'derived_supervisor_min');

    -- Skip junk rows: missing key, missing display, NULL rate, negative rate
    IF k = '' OR display = '' OR rate_in IS NULL OR rate_in < 0 THEN
      CONTINUE;
    END IF;
    -- Defensive: eval_rate must be NULL or non-negative
    IF eval_rate_in IS NOT NULL AND eval_rate_in < 0 THEN
      eval_rate_in := NULL;
    END IF;
    -- Defensive: source must be in the allowed set
    IF src NOT IN ('derived_assistant_mode', 'derived_supervisor_min',
                   'derived_supervisor_split', 'manual_override', 'memory_hit') THEN
      src := 'derived_supervisor_min';
    END IF;

    SELECT * INTO existing FROM clinician_medb_rates WHERE clinician_lookup_key = k;

    IF existing.id IS NULL THEN
      -- New row
      INSERT INTO clinician_medb_rates
        (clinician_lookup_key, clinician_display, discipline, rate, eval_rate, source, last_set_by)
      VALUES (k, display, disc, rate_in, eval_rate_in, src, auth.uid());
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
      -- Overwrite rate + eval_rate + source + actor
      UPDATE clinician_medb_rates SET
        clinician_display = display,
        discipline        = COALESCE(disc, discipline),
        rate              = rate_in,
        eval_rate         = eval_rate_in,
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

-- ── 4. list_clinician_medb_rates — adds eval_rate to return shape ─
-- DROP-then-CREATE because the return-row shape grows a new column.
DROP FUNCTION IF EXISTS public.list_clinician_medb_rates();

CREATE OR REPLACE FUNCTION public.list_clinician_medb_rates()
RETURNS TABLE (
  id                   UUID,
  clinician_lookup_key TEXT,
  clinician_display    TEXT,
  discipline           TEXT,
  rate                 NUMERIC,
  eval_rate            NUMERIC,
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
      r.eval_rate,
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

-- ── 5. lookup_clinician_medb_rate — keep existing single-rate read ─
-- The single-rate lookup function from migration 35 isn't called from
-- the client today (the bulk list RPC is used instead) but keep it
-- around for forward compat. Just re-create with the same signature
-- it had — no eval_rate dimension yet. If a future caller needs both
-- rates, we'll add lookup_clinician_medb_rates_pair() at that time.
-- (No DROP needed — signature unchanged from migration 35.)

COMMIT;

NOTIFY pgrst, 'reload schema';
