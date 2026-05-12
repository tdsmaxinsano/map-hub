-- Kanban Task Board: schema, indexes, RLS policies, and seed data.
-- Run in Supabase Dashboard -> SQL Editor.
-- Idempotent on re-run for the schema/policies; seed inserts use ON CONFLICT DO NOTHING.

BEGIN;

-- ────────────────────────────────────────────────────────────────────────────
-- 1. Boards (top-level workflows)
-- ────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.boards (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name        TEXT NOT NULL,
  slug        TEXT UNIQUE NOT NULL,
  icon        TEXT,
  position    INT NOT NULL DEFAULT 0,
  is_default  BOOLEAN NOT NULL DEFAULT false,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- ────────────────────────────────────────────────────────────────────────────
-- 2. Columns within each board
-- ────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.board_columns (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  board_id    UUID NOT NULL REFERENCES public.boards(id) ON DELETE CASCADE,
  name        TEXT NOT NULL,
  position    INT NOT NULL,
  is_done     BOOLEAN NOT NULL DEFAULT false,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS board_columns_board_position_idx
  ON public.board_columns (board_id, position);

-- ────────────────────────────────────────────────────────────────────────────
-- 3. Tasks
-- ────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.tasks (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  title           TEXT NOT NULL,
  description     TEXT,

  -- Workflow position
  board_id        UUID NOT NULL REFERENCES public.boards(id),
  column_id       UUID NOT NULL REFERENCES public.board_columns(id),
  position        INT NOT NULL DEFAULT 0,
  is_archived     BOOLEAN NOT NULL DEFAULT false,

  -- Cross-platform linking (nullable = freestanding)
  linked_entity_type   TEXT
                       CHECK (linked_entity_type IN ('clinician','referral','compliance_item','agency')),
  linked_entity_id     UUID,
  linked_entity_label  TEXT,

  -- Attribution
  created_by      UUID NOT NULL,
  assigned_to     UUID,

  -- SLA
  due_at          TIMESTAMPTZ,
  sla_preset      TEXT,

  -- Lifecycle
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  completed_at    TIMESTAMPTZ,
  archived_at     TIMESTAMPTZ
);
CREATE INDEX IF NOT EXISTS tasks_board_column_position_idx
  ON public.tasks (board_id, column_id, position);
CREATE INDEX IF NOT EXISTS tasks_linked_entity_idx
  ON public.tasks (linked_entity_type, linked_entity_id);
CREATE INDEX IF NOT EXISTS tasks_due_at_idx
  ON public.tasks (due_at) WHERE is_archived = false;

-- ────────────────────────────────────────────────────────────────────────────
-- RLS POLICIES
-- ────────────────────────────────────────────────────────────────────────────

-- Boards: SELECT for all authenticated; INSERT/UPDATE/DELETE only for admins.
ALTER TABLE public.boards ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "boards_select_authenticated" ON public.boards;
DROP POLICY IF EXISTS "boards_modify_admin" ON public.boards;
CREATE POLICY "boards_select_authenticated" ON public.boards
  FOR SELECT TO authenticated USING (true);
CREATE POLICY "boards_modify_admin" ON public.boards
  FOR ALL TO authenticated
  USING      (EXISTS (SELECT 1 FROM public.user_roles WHERE user_id = auth.uid() AND role = 'admin'))
  WITH CHECK (EXISTS (SELECT 1 FROM public.user_roles WHERE user_id = auth.uid() AND role = 'admin'));

-- Board columns: same pattern as boards.
ALTER TABLE public.board_columns ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "board_columns_select_authenticated" ON public.board_columns;
DROP POLICY IF EXISTS "board_columns_modify_admin" ON public.board_columns;
CREATE POLICY "board_columns_select_authenticated" ON public.board_columns
  FOR SELECT TO authenticated USING (true);
CREATE POLICY "board_columns_modify_admin" ON public.board_columns
  FOR ALL TO authenticated
  USING      (EXISTS (SELECT 1 FROM public.user_roles WHERE user_id = auth.uid() AND role = 'admin'))
  WITH CHECK (EXISTS (SELECT 1 FROM public.user_roles WHERE user_id = auth.uid() AND role = 'admin'));

-- Tasks: any authenticated user can do anything (matches "all staff create and edit").
ALTER TABLE public.tasks ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "tasks_authenticated_all" ON public.tasks;
CREATE POLICY "tasks_authenticated_all" ON public.tasks
  FOR ALL TO authenticated USING (true) WITH CHECK (true);

-- ────────────────────────────────────────────────────────────────────────────
-- SEED: Default boards + columns
-- ────────────────────────────────────────────────────────────────────────────
INSERT INTO public.boards (name, slug, icon, position, is_default) VALUES
  ('Referrals',  'referrals',  '📋', 0, true),
  ('Compliance', 'compliance', '✅', 1, false),
  ('General',    'general',    '🗒️', 2, false)
ON CONFLICT (slug) DO NOTHING;

-- Referral pipeline columns
INSERT INTO public.board_columns (board_id, name, position, is_done)
SELECT b.id, c.name, c.position, c.is_done FROM public.boards b
CROSS JOIN (VALUES
  ('Open',       0, false),
  ('Contacted',  1, false),
  ('Confirmed',  2, false),
  ('Done',       3, true)
) AS c(name, position, is_done)
WHERE b.slug = 'referrals'
  AND NOT EXISTS (SELECT 1 FROM public.board_columns bc WHERE bc.board_id = b.id AND bc.name = c.name);

-- Compliance columns
INSERT INTO public.board_columns (board_id, name, position, is_done)
SELECT b.id, c.name, c.position, c.is_done FROM public.boards b
CROSS JOIN (VALUES
  ('To Review',     0, false),
  ('In Progress',   1, false),
  ('Awaiting Doc',  2, false),
  ('Resolved',      3, true)
) AS c(name, position, is_done)
WHERE b.slug = 'compliance'
  AND NOT EXISTS (SELECT 1 FROM public.board_columns bc WHERE bc.board_id = b.id AND bc.name = c.name);

-- General columns
INSERT INTO public.board_columns (board_id, name, position, is_done)
SELECT b.id, c.name, c.position, c.is_done FROM public.boards b
CROSS JOIN (VALUES
  ('To Do',  0, false),
  ('Doing',  1, false),
  ('Done',   2, true)
) AS c(name, position, is_done)
WHERE b.slug = 'general'
  AND NOT EXISTS (SELECT 1 FROM public.board_columns bc WHERE bc.board_id = b.id AND bc.name = c.name);

COMMIT;
