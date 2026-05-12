-- Auto-create staff_config row for every signup
-- =================================================================
-- Problem: when a user signs up via supabase.auth.signUp, rows are
-- inserted into auth.users (and now public.user_roles via the trigger
-- from 05_auto_user_role.sql). However, public.staff_config — which
-- the time-tracker admin dashboard reads exclusively from — gets
-- nothing. Result: new users are invisible on the time-tracker admin
-- dashboard, even though admins can already promote their roles.
--
-- Fix:
--   1. Backfill: for every auth.users without a staff_config row,
--      insert one with is_active=false and a placeholder display_name
--      derived from the email prefix. hourly_rate=0 so payroll math
--      stays clean.
--   2. Trigger: AFTER INSERT on auth.users, auto-insert the same
--      default staff_config row. SECURITY DEFINER so it works under
--      any RLS state.
--
-- Defaults match what the existing "Add Staff Member" modal pre-fills,
-- so the admin's "Set up" experience is unchanged — they just edit
-- an already-existing row instead of creating one from scratch.
--
-- Run in Supabase Dashboard -> SQL Editor. Idempotent — safe to re-run.

BEGIN;

-- ─── Step 1: Backfill missing staff_config entries ────────────────
INSERT INTO public.staff_config (
  user_id, display_name, hourly_rate, pay_type, timezone, is_active
)
SELECT
  u.id,
  SPLIT_PART(u.email::text, '@', 1),  -- placeholder display name from email
  0.00,                                 -- rate must be set manually
  'philippines',                        -- most common pay type today
  'Asia/Manila',                        -- matches Add Staff modal default
  false                                 -- inactive until admin completes setup
FROM auth.users u
LEFT JOIN public.staff_config sc ON sc.user_id = u.id
WHERE sc.user_id IS NULL
ON CONFLICT (user_id) DO NOTHING;

-- ─── Step 2: Trigger function ─────────────────────────────────────
CREATE OR REPLACE FUNCTION public.handle_new_user_staff()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  INSERT INTO public.staff_config (
    user_id, display_name, hourly_rate, pay_type, timezone, is_active
  )
  VALUES (
    NEW.id,
    SPLIT_PART(NEW.email::text, '@', 1),
    0.00,
    'philippines',
    'Asia/Manila',
    false
  )
  ON CONFLICT (user_id) DO NOTHING;
  RETURN NEW;
END;
$$;

-- ─── Step 3: Wire the trigger on auth.users ───────────────────────
DROP TRIGGER IF EXISTS on_auth_user_created_staff ON auth.users;
CREATE TRIGGER on_auth_user_created_staff
  AFTER INSERT ON auth.users
  FOR EACH ROW
  EXECUTE FUNCTION public.handle_new_user_staff();

COMMIT;
