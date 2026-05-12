-- Staff directory + admin profile management
-- ============================================
-- 1. Adds display_color + photo_url columns to staff_config
-- 2. list_staff() returns user_id + email + display_name + display_color + photo_url + role
--    (SECURITY DEFINER so it bypasses auth.users RLS)
-- 3. upsert_staff_profile() — admin-only, sets all three customizable fields
-- 4. staff-photos storage bucket (public-read, admin-write) for headshot uploads
--
-- Run in Supabase Dashboard -> SQL Editor. Idempotent — safe to re-run.

BEGIN;

-- ─── Schema additions to staff_config ─────────────────────────────────────
ALTER TABLE public.staff_config
  ADD COLUMN IF NOT EXISTS display_color TEXT,
  ADD COLUMN IF NOT EXISTS photo_url     TEXT;

-- ─── Drop any prior versions of the directory artifacts ───────────────────
DROP VIEW     IF EXISTS public.staff_directory;
DROP FUNCTION IF EXISTS public.list_staff();
DROP FUNCTION IF EXISTS public.upsert_staff_display_name(UUID, TEXT);
DROP FUNCTION IF EXISTS public.upsert_staff_profile(UUID, TEXT, TEXT, TEXT);

-- ─── list_staff() ─────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.list_staff()
RETURNS TABLE(
  user_id       UUID,
  email         TEXT,
  display_name  TEXT,
  display_color TEXT,
  photo_url     TEXT,
  role          TEXT
)
LANGUAGE sql
SECURITY DEFINER
SET search_path = public, auth
AS $$
  SELECT
    u.id,
    u.email::text,
    sc.display_name,
    sc.display_color,
    sc.photo_url,
    ur.role
  FROM auth.users u
  LEFT JOIN public.user_roles    ur ON ur.user_id = u.id
  LEFT JOIN public.staff_config  sc ON sc.user_id = u.id
  ORDER BY COALESCE(sc.display_name, u.email::text);
$$;

REVOKE ALL ON FUNCTION public.list_staff() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.list_staff() TO authenticated;

-- ─── upsert_staff_profile(user_id, display_name, display_color, photo_url) ─
-- Admin-only. Any field passed as NULL is left unchanged on existing rows.
-- (Empty string clears the value; pass NULL to leave it alone.)
CREATE OR REPLACE FUNCTION public.upsert_staff_profile(
  p_user_id        UUID,
  p_display_name   TEXT DEFAULT NULL,
  p_display_color  TEXT DEFAULT NULL,
  p_photo_url      TEXT DEFAULT NULL
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  -- Only admins
  IF NOT EXISTS (
    SELECT 1 FROM public.user_roles
    WHERE user_id = auth.uid() AND role = 'admin'
  ) THEN
    RAISE EXCEPTION 'Only admins can set staff profiles';
  END IF;

  INSERT INTO public.staff_config (user_id, display_name, display_color, photo_url)
  VALUES (
    p_user_id,
    NULLIF(TRIM(COALESCE(p_display_name,  '')), ''),
    NULLIF(TRIM(COALESCE(p_display_color, '')), ''),
    NULLIF(TRIM(COALESCE(p_photo_url,     '')), '')
  )
  ON CONFLICT (user_id) DO UPDATE SET
    display_name  = COALESCE(NULLIF(TRIM(COALESCE(EXCLUDED.display_name,  '')), ''), staff_config.display_name),
    display_color = COALESCE(NULLIF(TRIM(COALESCE(EXCLUDED.display_color, '')), ''), staff_config.display_color),
    photo_url     = COALESCE(NULLIF(TRIM(COALESCE(EXCLUDED.photo_url,     '')), ''), staff_config.photo_url);
END;
$$;

REVOKE ALL ON FUNCTION public.upsert_staff_profile(UUID, TEXT, TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.upsert_staff_profile(UUID, TEXT, TEXT, TEXT) TO authenticated;

-- ─── clear_staff_field(user_id, field_name) ───────────────────────────────
-- Admin-only. Lets the UI explicitly NULL out a field (since the upsert
-- above treats NULL as "leave alone"). Field name must be one of:
-- 'display_name', 'display_color', 'photo_url'.
DROP FUNCTION IF EXISTS public.clear_staff_field(UUID, TEXT);
CREATE OR REPLACE FUNCTION public.clear_staff_field(p_user_id UUID, p_field TEXT)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM public.user_roles
    WHERE user_id = auth.uid() AND role = 'admin'
  ) THEN
    RAISE EXCEPTION 'Only admins can clear staff fields';
  END IF;

  IF p_field = 'display_name' THEN
    UPDATE public.staff_config SET display_name  = NULL WHERE user_id = p_user_id;
  ELSIF p_field = 'display_color' THEN
    UPDATE public.staff_config SET display_color = NULL WHERE user_id = p_user_id;
  ELSIF p_field = 'photo_url' THEN
    UPDATE public.staff_config SET photo_url     = NULL WHERE user_id = p_user_id;
  ELSE
    RAISE EXCEPTION 'Invalid field: %', p_field;
  END IF;
END;
$$;

REVOKE ALL ON FUNCTION public.clear_staff_field(UUID, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.clear_staff_field(UUID, TEXT) TO authenticated;

-- ─── Storage: staff-photos bucket ─────────────────────────────────────────
-- Public-read so <img src="..."> works without signed URLs.
-- Only admins can write (upload/update/delete).
INSERT INTO storage.buckets (id, name, public)
VALUES ('staff-photos', 'staff-photos', true)
ON CONFLICT (id) DO UPDATE SET public = true;

-- Read access for any authenticated user
DROP POLICY IF EXISTS "staff_photos_read_authenticated" ON storage.objects;
CREATE POLICY "staff_photos_read_authenticated" ON storage.objects
  FOR SELECT TO authenticated
  USING (bucket_id = 'staff-photos');

-- Write access (insert/update/delete) only for admins
DROP POLICY IF EXISTS "staff_photos_admin_write" ON storage.objects;
CREATE POLICY "staff_photos_admin_write" ON storage.objects
  FOR ALL TO authenticated
  USING (
    bucket_id = 'staff-photos' AND
    EXISTS (SELECT 1 FROM public.user_roles WHERE user_id = auth.uid() AND role = 'admin')
  )
  WITH CHECK (
    bucket_id = 'staff-photos' AND
    EXISTS (SELECT 1 FROM public.user_roles WHERE user_id = auth.uid() AND role = 'admin')
  );

COMMIT;
