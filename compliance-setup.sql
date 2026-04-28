-- ══════════════════════════════════════════════════
--  DCS Compliance Tracker — Supabase Setup
--  Run this in the Supabase SQL Editor
-- ══════════════════════════════════════════════════

-- 1. Import batches (one per TB file upload)
CREATE TABLE IF NOT EXISTS compliance_imports (
  id           uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  imported_by  uuid        REFERENCES auth.users(id),
  imported_at  timestamptz NOT NULL DEFAULT now(),
  filename     text,
  period_label text,        -- e.g. "Week of Apr 12, 2026"
  row_count    int
);

-- 2. Individual compliance line items
CREATE TABLE IF NOT EXISTS compliance_items (
  id                uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  import_id         uuid        REFERENCES compliance_imports(id) ON DELETE CASCADE,
  agency            text        NOT NULL,
  patient_name      text        NOT NULL,
  episode           text,
  period_date       date,
  service           text,
  freq_ordered      int         NOT NULL DEFAULT 0,
  scheduled         int         NOT NULL DEFAULT 0,
  completed         int         NOT NULL DEFAULT 0,
  additional_visits int         NOT NULL DEFAULT 0,
  missed_visits     int         NOT NULL DEFAULT 0,
  clinician_raw     text,
  is_hot            boolean     NOT NULL DEFAULT false,
  hot_note          text,
  clinician_states  jsonb       NOT NULL DEFAULT '{}',  -- per-clinician notes + done flags
  is_done           boolean     NOT NULL DEFAULT false,
  done_at           timestamptz,
  done_by           uuid        REFERENCES auth.users(id),
  done_by_email     text,
  created_at        timestamptz NOT NULL DEFAULT now()
);

-- 3. Indexes for common lookups
CREATE INDEX IF NOT EXISTS idx_compliance_items_import_id
  ON compliance_items (import_id);

CREATE INDEX IF NOT EXISTS idx_compliance_items_is_hot
  ON compliance_items (is_hot)
  WHERE is_hot = true;

CREATE INDEX IF NOT EXISTS idx_compliance_items_is_done
  ON compliance_items (is_done);

CREATE INDEX IF NOT EXISTS idx_compliance_items_period_date
  ON compliance_items (period_date);

-- 4. Enable Row Level Security
ALTER TABLE compliance_imports ENABLE ROW LEVEL SECURITY;
ALTER TABLE compliance_items   ENABLE ROW LEVEL SECURITY;

-- 5. Allow any authenticated user to read and write
--    (same open policy as clinician profiles — portal login required)
DROP POLICY IF EXISTS "compliance_imports_auth" ON compliance_imports;
CREATE POLICY "compliance_imports_auth" ON compliance_imports
  FOR ALL TO authenticated
  USING (true)
  WITH CHECK (true);

DROP POLICY IF EXISTS "compliance_items_auth" ON compliance_items;
CREATE POLICY "compliance_items_auth" ON compliance_items
  FOR ALL TO authenticated
  USING (true)
  WITH CHECK (true);

-- ══════════════════════════════════════════════════
--  Migration: add per-clinician state column
--  Run this if you already created the table above
-- ══════════════════════════════════════════════════
ALTER TABLE compliance_items
  ADD COLUMN IF NOT EXISTS clinician_states jsonb NOT NULL DEFAULT '{}';

-- ══════════════════════════════════════════════════
--  Migration: status system + manual entry fields
--  Run these if the table already exists
-- ══════════════════════════════════════════════════
ALTER TABLE compliance_items
  ADD COLUMN IF NOT EXISTS status text NOT NULL DEFAULT 'Not Started';

ALTER TABLE compliance_items
  ADD COLUMN IF NOT EXISTS task_description text;

ALTER TABLE compliance_items
  ADD COLUMN IF NOT EXISTS attempted_visits int NOT NULL DEFAULT 0;

-- Rename AV column if it was created as additional_visits
-- (skip if column already named attempted_visits)
DO $$ BEGIN
  IF EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_name='compliance_items' AND column_name='additional_visits'
  ) THEN
    ALTER TABLE compliance_items RENAME COLUMN additional_visits TO attempted_visits;
  END IF;
END $$;

-- Back-fill is_done rows into status
UPDATE compliance_items SET status = 'Done' WHERE is_done = true AND status = 'Not Started';
