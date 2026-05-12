-- Auto-create user_roles row for every signup
-- =================================================================
-- Problem: when a new user signs up via supabase.auth.signUp, a row
-- is inserted into auth.users but nothing populates public.user_roles.
-- Result: new users are invisible to the admin Manage Users panel
-- (which only queries user_roles), and their role lookups fall back
-- to "readonly" via the application code — but admins can't promote
-- them because they don't appear in the list.
--
-- Fix:
--   1. Backfill: for every existing auth.users row that doesn't have
--      a user_roles entry, insert one with role='readonly'.
--   2. Trigger: AFTER INSERT on auth.users, auto-insert a user_roles
--      row with role='readonly'. SECURITY DEFINER so it works even
--      while RLS is enabled on user_roles.
--
-- Run in Supabase Dashboard -> SQL Editor. Idempotent — safe to re-run.

BEGIN;

-- ─── Step 1: Backfill missing user_roles entries ──────────────────
INSERT INTO public.user_roles (user_id, email, role)
SELECT u.id, u.email::text, 'readonly'
FROM auth.users u
LEFT JOIN public.user_roles ur ON ur.user_id = u.id
WHERE ur.user_id IS NULL
ON CONFLICT (user_id) DO NOTHING;

-- ─── Step 2: Trigger function to auto-create the row on signup ────
CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  INSERT INTO public.user_roles (user_id, email, role)
  VALUES (NEW.id, NEW.email::text, 'readonly')
  ON CONFLICT (user_id) DO NOTHING;
  RETURN NEW;
END;
$$;

-- ─── Step 3: Wire the trigger on auth.users ───────────────────────
DROP TRIGGER IF EXISTS on_auth_user_created ON auth.users;
CREATE TRIGGER on_auth_user_created
  AFTER INSERT ON auth.users
  FOR EACH ROW
  EXECUTE FUNCTION public.handle_new_user();

COMMIT;
