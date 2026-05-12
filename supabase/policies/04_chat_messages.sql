-- chat_messages: portal-wide team chat
-- ============================================
-- Single channel; every authenticated user can send + read every message.
-- Realtime subscription on this table broadcasts new messages to all
-- connected portal pages instantly.
--
-- Run in Supabase Dashboard -> SQL Editor.

BEGIN;

CREATE TABLE IF NOT EXISTS public.chat_messages (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id     UUID NOT NULL,
  content     TEXT NOT NULL CHECK (length(content) > 0 AND length(content) <= 2000),
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS chat_messages_created_at_idx
  ON public.chat_messages (created_at DESC);

ALTER TABLE public.chat_messages ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "chat_messages_select_authenticated" ON public.chat_messages;
DROP POLICY IF EXISTS "chat_messages_insert_authenticated" ON public.chat_messages;
DROP POLICY IF EXISTS "chat_messages_update_own" ON public.chat_messages;
DROP POLICY IF EXISTS "chat_messages_delete_own" ON public.chat_messages;

-- Everyone signed in can see all messages
CREATE POLICY "chat_messages_select_authenticated" ON public.chat_messages
  FOR SELECT TO authenticated USING (true);

-- Anyone signed in can post a message AS THEMSELVES (user_id must match auth.uid)
CREATE POLICY "chat_messages_insert_authenticated" ON public.chat_messages
  FOR INSERT TO authenticated
  WITH CHECK (user_id = auth.uid());

-- Users can edit/delete only their own messages
CREATE POLICY "chat_messages_update_own" ON public.chat_messages
  FOR UPDATE TO authenticated USING (user_id = auth.uid()) WITH CHECK (user_id = auth.uid());
CREATE POLICY "chat_messages_delete_own" ON public.chat_messages
  FOR DELETE TO authenticated USING (user_id = auth.uid());

-- ─── Enable realtime broadcasts for this table ──────────────────────────────
-- New tables in Supabase aren't automatically broadcast via Realtime — they
-- have to be added to the supabase_realtime publication. Without this, INSERT
-- events don't reach the chat-widget's .on("postgres_changes") handler, so
-- new messages only appear after a page reload. (Wrapped in DO block to be
-- idempotent — won't error if the table is already in the publication.)
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_publication_tables
    WHERE pubname = 'supabase_realtime' AND schemaname = 'public' AND tablename = 'chat_messages'
  ) THEN
    EXECUTE 'ALTER PUBLICATION supabase_realtime ADD TABLE public.chat_messages';
  END IF;
END $$;

COMMIT;
