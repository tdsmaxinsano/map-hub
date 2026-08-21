-- Clinician address-change review queue — Sync Update move detections
-- =====================================================================
-- The Map's clinician Sync Update import applies a new TherapyBoss
-- address (and re-geocoded home pin) immediately, but TB never says WHEN
-- the therapist moved — so the territory side (Ignore-History-Before
-- cutoff + new ZIP plan) can't be automated. Each detected address
-- change is ALSO queued here for human review:
--   * surfaced as 🏠 cards on the Home 📰 News & Alerts board
--     (click-through opens that clinician's Territory Planner), and
--   * as a step-0 banner on the planner's 📦 Therapist moved card.
-- Saving an Ignore-History-Before cutoff (or staging a ZIP plan) in the
-- planner marks the row processed — the chosen cutoff date is stamped
-- as move_date. "✕ Not a move" dismisses false alarms (typo fixes,
-- Apt-number corrections).
--
-- Queue semantics (enforced client-side, guarded here):
--   * ONE pending row per clinician — a re-detection updates it in
--     place (new_address/new_zip/detected_at bump; old_address is never
--     touched: the original "before" is the true pre-move address).
--   * A dismissed row suppresses re-queueing of the SAME (normalized)
--     new address only; a different address queues fresh.
--   * Processed rows never suppress — a later move queues fresh.
--
-- clinician_name / discipline are denormalized at detection time so the
-- Home board can render from a plain SELECT with no join.
--
-- RLS: SELECT authenticated (everyone sees the alerts); writes
-- admin+editor. Idempotent — safe to re-run. Run after
-- 61_site_exclusions.sql.

BEGIN;

CREATE TABLE IF NOT EXISTS public.clinician_address_changes (
  id                 UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  clinician_id       UUID NOT NULL REFERENCES public.clinician_v2(id) ON DELETE CASCADE,
  clinician_name     TEXT,            -- denormalized: Home board renders without a join
  discipline         TEXT,            -- denormalized, same reason
  old_address        TEXT,
  new_address        TEXT,
  old_zip            TEXT,
  new_zip            TEXT,
  detected_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
  detected_by_email  TEXT,
  source             TEXT NOT NULL DEFAULT 'sync_update',
  status             TEXT NOT NULL DEFAULT 'pending'
                       CHECK (status IN ('pending','processed','dismissed')),
  processed_at       TIMESTAMPTZ,
  processed_by_email TEXT,
  move_date          DATE,            -- stamped when the planner cutoff resolves it
  note               TEXT
);

-- Self-healing: if a clinician_address_changes table already exists in
-- some other/partial shape (CREATE TABLE IF NOT EXISTS skips it and the
-- index below then errors 42703 on the missing column), add any missing
-- columns. No-ops on a freshly created table. Data, if any, is kept.
ALTER TABLE public.clinician_address_changes ADD COLUMN IF NOT EXISTS id                 UUID DEFAULT gen_random_uuid();
ALTER TABLE public.clinician_address_changes ADD COLUMN IF NOT EXISTS clinician_id       UUID;
ALTER TABLE public.clinician_address_changes ADD COLUMN IF NOT EXISTS clinician_name     TEXT;
ALTER TABLE public.clinician_address_changes ADD COLUMN IF NOT EXISTS discipline         TEXT;
ALTER TABLE public.clinician_address_changes ADD COLUMN IF NOT EXISTS old_address        TEXT;
ALTER TABLE public.clinician_address_changes ADD COLUMN IF NOT EXISTS new_address        TEXT;
ALTER TABLE public.clinician_address_changes ADD COLUMN IF NOT EXISTS old_zip            TEXT;
ALTER TABLE public.clinician_address_changes ADD COLUMN IF NOT EXISTS new_zip            TEXT;
ALTER TABLE public.clinician_address_changes ADD COLUMN IF NOT EXISTS detected_at        TIMESTAMPTZ NOT NULL DEFAULT now();
ALTER TABLE public.clinician_address_changes ADD COLUMN IF NOT EXISTS detected_by_email  TEXT;
ALTER TABLE public.clinician_address_changes ADD COLUMN IF NOT EXISTS source             TEXT NOT NULL DEFAULT 'sync_update';
ALTER TABLE public.clinician_address_changes ADD COLUMN IF NOT EXISTS status             TEXT NOT NULL DEFAULT 'pending';
ALTER TABLE public.clinician_address_changes ADD COLUMN IF NOT EXISTS processed_at       TIMESTAMPTZ;
ALTER TABLE public.clinician_address_changes ADD COLUMN IF NOT EXISTS processed_by_email TEXT;
ALTER TABLE public.clinician_address_changes ADD COLUMN IF NOT EXISTS move_date          DATE;
ALTER TABLE public.clinician_address_changes ADD COLUMN IF NOT EXISTS note               TEXT;

-- Ensure the status CHECK exists even when the column pre-dated us
-- (ADD COLUMN IF NOT EXISTS skips its inline CHECK on an existing column).
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'clinician_address_changes_status_check'
      AND conrelid = 'public.clinician_address_changes'::regclass
  ) THEN
    ALTER TABLE public.clinician_address_changes
      ADD CONSTRAINT clinician_address_changes_status_check
      CHECK (status IN ('pending','processed','dismissed'));
  END IF;
END $$;

-- Same for the clinician FK (drives ON DELETE CASCADE cleanup). Guarded
-- with an exception handler: if a pre-existing clinician_id column has an
-- incompatible type or orphan values, we keep the table usable and just
-- note it instead of failing the whole migration.
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'clinician_address_changes_clinician_id_fkey'
      AND conrelid = 'public.clinician_address_changes'::regclass
  ) THEN
    BEGIN
      ALTER TABLE public.clinician_address_changes
        ADD CONSTRAINT clinician_address_changes_clinician_id_fkey
        FOREIGN KEY (clinician_id) REFERENCES public.clinician_v2(id) ON DELETE CASCADE;
    EXCEPTION WHEN others THEN
      RAISE NOTICE 'clinician_address_changes: FK not added (%)', SQLERRM;
    END;
  END IF;
END $$;

CREATE INDEX IF NOT EXISTS idx_addr_chg_clinician
  ON public.clinician_address_changes (clinician_id, detected_at DESC);

-- Invariant guard: at most ONE pending row per clinician. The client
-- never upserts against this (PostgREST can't target a partial index) —
-- it SELECTs pending rows and UPDATEs by id; this index just makes a
-- racing double-import fail loudly (caught non-fatally) instead of
-- silently duplicating.
CREATE UNIQUE INDEX IF NOT EXISTS idx_addr_chg_one_pending
  ON public.clinician_address_changes (clinician_id) WHERE status = 'pending';

COMMENT ON TABLE public.clinician_address_changes IS
  'Review queue of Sync-Update-detected clinician address changes (moves). TB never supplies the move date, so a human processes each via the Territory Planner (cutoff date → move_date). One pending row per clinician; dismissed rows suppress the same address only.';

ALTER TABLE public.clinician_address_changes ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "addr_chg_select_auth"        ON public.clinician_address_changes;
DROP POLICY IF EXISTS "addr_chg_write_editor_admin" ON public.clinician_address_changes;

CREATE POLICY "addr_chg_select_auth" ON public.clinician_address_changes
  FOR SELECT TO authenticated USING (true);

CREATE POLICY "addr_chg_write_editor_admin" ON public.clinician_address_changes
  FOR ALL TO authenticated
  USING      (EXISTS (SELECT 1 FROM public.user_roles ur
                      WHERE ur.user_id = auth.uid() AND ur.role IN ('admin','editor')))
  WITH CHECK (EXISTS (SELECT 1 FROM public.user_roles ur
                      WHERE ur.user_id = auth.uid() AND ur.role IN ('admin','editor')));

COMMIT;

NOTIFY pgrst, 'reload schema';
