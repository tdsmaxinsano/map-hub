-- ════════════════════════════════════════════════════════════════════
-- 103 · QB customers to create (Finance → QB Tools → Bank Match ③)
--
-- Every "Received From" name Bank Match sends to QuickBooks (deposit
-- XLSX downloads, insurance / patient check scans) is noted here. QB
-- only attaches a name to an imported deposit when that customer
-- already exists, so this list tracks which names still need creating:
--   pending → exported (QB import CSV downloaded) → in_qb (confirmed)
--
-- note_qb_customers() only inserts new names / bumps last_seen +
-- seen_count — it NEVER changes status, so a name marked in_qb stays
-- done no matter how often it's used again.
--
-- RLS: admin-only (same as migration 102). Idempotent.
-- ════════════════════════════════════════════════════════════════════
BEGIN;

CREATE TABLE IF NOT EXISTS public.qb_customer_queue (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name        TEXT NOT NULL,
  kind        TEXT NOT NULL DEFAULT 'other',      -- insurance | patient | other
  source      TEXT,                               -- bank-match | ins-scan | patient-scan | manual
  first_seen  TIMESTAMPTZ NOT NULL DEFAULT now(),
  last_seen   TIMESTAMPTZ NOT NULL DEFAULT now(),
  seen_count  INTEGER NOT NULL DEFAULT 1,
  status      TEXT NOT NULL DEFAULT 'pending',    -- pending | exported | in_qb
  exported_at TIMESTAMPTZ,
  in_qb_at    TIMESTAMPTZ,
  notes       TEXT,
  CONSTRAINT qb_customer_queue_status_chk CHECK (status IN ('pending','exported','in_qb')),
  CONSTRAINT qb_customer_queue_kind_chk   CHECK (kind IN ('insurance','patient','other'))
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_qb_customer_queue_name
  ON public.qb_customer_queue (lower(btrim(name)));

ALTER TABLE public.qb_customer_queue ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "qb_customer_queue_admin_all" ON public.qb_customer_queue;
CREATE POLICY "qb_customer_queue_admin_all" ON public.qb_customer_queue
  FOR ALL TO authenticated
  USING (EXISTS (SELECT 1 FROM public.user_roles ur
                 WHERE ur.user_id = auth.uid() AND ur.role = 'admin'))
  WITH CHECK (EXISTS (SELECT 1 FROM public.user_roles ur
                      WHERE ur.user_id = auth.uid() AND ur.role = 'admin'));

-- Note a batch of names. New → pending; existing → last_seen / seen_count
-- bumped (status untouched). SECURITY INVOKER: RLS still applies.
CREATE OR REPLACE FUNCTION public.note_qb_customers(
  p_names  TEXT[],
  p_kind   TEXT DEFAULT 'other',
  p_source TEXT DEFAULT 'bank-match'
) RETURNS INTEGER
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public
AS $$
DECLARE
  n   TEXT;
  cnt INTEGER := 0;
  k   TEXT := CASE WHEN p_kind IN ('insurance','patient','other') THEN p_kind ELSE 'other' END;
BEGIN
  FOREACH n IN ARRAY COALESCE(p_names, ARRAY[]::TEXT[]) LOOP
    n := btrim(n);
    CONTINUE WHEN n IS NULL OR n = '';
    INSERT INTO public.qb_customer_queue (name, kind, source)
    VALUES (n, k, p_source)
    ON CONFLICT (lower(btrim(name))) DO UPDATE
      SET last_seen  = now(),
          seen_count = public.qb_customer_queue.seen_count + 1;
    cnt := cnt + 1;
  END LOOP;
  RETURN cnt;
END;
$$;

GRANT EXECUTE ON FUNCTION public.note_qb_customers(TEXT[], TEXT, TEXT) TO authenticated;

NOTIFY pgrst, 'reload schema';

COMMIT;
