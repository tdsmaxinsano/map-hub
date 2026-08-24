-- Invite-only signup + pending gate + clinician role groundwork
-- =====================================================================
-- Until now anyone with the portal URL could self-signup and land as
-- 'readonly' (which, pre-Phase-2 RLS, is a UI label — not a security
-- boundary). This migration makes signup INVITE-DRIVEN:
--
--   * New public.user_invites table — one open invite per email
--     (email_norm UNIQUE). Admin sends invites from the Map's 👥 Users
--     modal via the new send-user-invite Edge Function (SendGrid).
--   * handle_new_user() (migration 05) is rebuilt: when a new
--     auth.users row's email matches an OPEN invite (not revoked, not
--     accepted), the account gets the INVITED role (+ clinician link,
--     for clinician invites) and the invite is stamped accepted.
--     No invite → role 'pending' — the shell shows only a
--     "waiting for approval" screen and loads no data.
--   * user_roles gains two new allowed roles — 'pending' and
--     'clinician' — via a guarded CHECK rebuild (the table predates
--     this repo, so any existing CHECK on role is dropped first), and
--     a clinician_id UUID column linking a portal account to its
--     clinician_v2 record (drives the clinician role's own-territory
--     view; NULL for office staff).
--
-- Deployment order matters: deploy the updated pages BEFORE running
-- this migration (so the pending gate is live before 'pending' can be
-- assigned), and deploy the send-user-invite function + SendGrid
-- secrets for the invite emails. Keep Supabase "Enable signups" ON —
-- invite-only is enforced by role assignment, not by disabling signup.
--
-- Server-side per-role RLS is still the Phase-2 backlog item — the
-- pending/clinician gates are UI-level in this revision.
--
-- Migration 06 (auto staff_config row) is untouched.
-- Idempotent — safe to re-run. Run after 63_clinician_loaded_at.sql.

BEGIN;

-- ── 1. user_roles.role CHECK rebuild ─────────────────────────────────
-- The table was created out-of-band; whether a CHECK exists (and its
-- name) is unknown. Drop ANY check constraint on user_roles that
-- mentions role, then add ours with the two new values.
DO $$
DECLARE con RECORD;
BEGIN
  FOR con IN
    SELECT c.conname
    FROM pg_constraint c
    JOIN pg_class t ON t.oid = c.conrelid
    JOIN pg_namespace n ON n.oid = t.relnamespace
    WHERE n.nspname = 'public' AND t.relname = 'user_roles'
      AND c.contype = 'c'
      AND pg_get_constraintdef(c.oid) ILIKE '%role%'
  LOOP
    EXECUTE format('ALTER TABLE public.user_roles DROP CONSTRAINT %I', con.conname);
  END LOOP;
  EXECUTE 'ALTER TABLE public.user_roles ADD CONSTRAINT user_roles_role_check
    CHECK (role IN (''admin'',''editor'',''readonly'',''pending'',''clinician''))';
END $$;

-- ── 2. Portal account ↔ clinician link ───────────────────────────────
ALTER TABLE public.user_roles ADD COLUMN IF NOT EXISTS clinician_id UUID;

DO $$
BEGIN
  ALTER TABLE public.user_roles
    ADD CONSTRAINT user_roles_clinician_fk
    FOREIGN KEY (clinician_id) REFERENCES public.clinician_v2(id) ON DELETE SET NULL;
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

COMMENT ON COLUMN public.user_roles.clinician_id IS
  'For role=clinician: the clinician_v2 record this portal account belongs to — drives the own-territory view. NULL for office staff.';

-- ── 3. Invites ───────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.user_invites (
  id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  email            TEXT NOT NULL,
  email_norm       TEXT GENERATED ALWAYS AS (lower(btrim(email))) STORED UNIQUE,
  role             TEXT NOT NULL CHECK (role IN ('admin','editor','readonly','clinician')),
  clinician_id     UUID REFERENCES public.clinician_v2(id) ON DELETE SET NULL,
  invited_by_email TEXT,
  invited_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
  accepted_at      TIMESTAMPTZ,
  accepted_user_id UUID,
  revoked_at       TIMESTAMPTZ
);

COMMENT ON TABLE public.user_invites IS
  'One invite per email (UNIQUE on normalized address; re-invites revive the row). handle_new_user() assigns the invited role at signup; uninvited signups become role=pending.';

ALTER TABLE public.user_invites ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "user_invites_admin_all" ON public.user_invites;
CREATE POLICY "user_invites_admin_all" ON public.user_invites
  FOR ALL TO authenticated
  USING      (EXISTS (SELECT 1 FROM public.user_roles ur
                      WHERE ur.user_id = auth.uid() AND ur.role = 'admin'))
  WITH CHECK (EXISTS (SELECT 1 FROM public.user_roles ur
                      WHERE ur.user_id = auth.uid() AND ur.role = 'admin'));

-- ── 4. Trigger rebuild: invited → invited role; uninvited → pending ──
-- SECURITY DEFINER, so user_invites RLS never blocks the lookup.
CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  inv public.user_invites%ROWTYPE;
BEGIN
  SELECT * INTO inv
  FROM public.user_invites
  WHERE email_norm = lower(btrim(NEW.email::text))
    AND revoked_at IS NULL
    AND accepted_at IS NULL
  LIMIT 1;

  IF FOUND THEN
    INSERT INTO public.user_roles (user_id, email, role, clinician_id)
    VALUES (NEW.id, NEW.email::text, inv.role, inv.clinician_id)
    ON CONFLICT (user_id) DO NOTHING;

    UPDATE public.user_invites
    SET accepted_at = now(), accepted_user_id = NEW.id
    WHERE id = inv.id;
  ELSE
    INSERT INTO public.user_roles (user_id, email, role)
    VALUES (NEW.id, NEW.email::text, 'pending')
    ON CONFLICT (user_id) DO NOTHING;
  END IF;

  RETURN NEW;
END;
$$;

-- Re-issue the trigger for idempotency (05 created it pointing at the
-- same function name, but a fresh DB running only this file also works).
DROP TRIGGER IF EXISTS on_auth_user_created ON auth.users;
CREATE TRIGGER on_auth_user_created
  AFTER INSERT ON auth.users
  FOR EACH ROW EXECUTE FUNCTION public.handle_new_user();

COMMIT;

NOTIFY pgrst, 'reload schema';
