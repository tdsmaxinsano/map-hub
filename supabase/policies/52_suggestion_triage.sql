-- Suggestion-tray triage — 3-tier ✓ Accept / 🤔 Potential / ✕ Reject
-- =====================================================================
-- The Suggested Clinicians tray (referrals.html, backed by migration 51)
-- was subtract-only: ✕ dismissed a candidate in browser memory, lost on
-- reload. This adds persistent, shared triage: every suggested clinician
-- can be sorted into accept / maybe (the "potential" bench) / reject,
-- stamped who + when, visible to every coordinator.
--
--   referrals.suggestion_triage JSONB:
--     { "<clinician_uuid>": { "t":  "accept" | "maybe" | "reject",
--                             "at": "<timestamptz>",
--                             "by": "<email>" } }
--
-- Writes go through set_referral_suggestion_tier(), which merges the one
-- key server-side — two coordinators triaging the same referral at once
-- can't clobber each other the way whole-column client updates would.
-- p_tier NULL removes the key (the card returns to Undecided).
--
-- Idempotent — safe to re-run. Run after 51_suggest_clinicians_for_referral.sql.

BEGIN;

-- ── 1. Triage column ─────────────────────────────────────────────────
ALTER TABLE public.referrals
  ADD COLUMN IF NOT EXISTS suggestion_triage JSONB NOT NULL DEFAULT '{}'::jsonb;

COMMENT ON COLUMN public.referrals.suggestion_triage IS
  'Per-clinician triage of the Suggested Clinicians tray: {clinician_id: {t: accept|maybe|reject, at, by}}. Written only via set_referral_suggestion_tier().';

-- ── 2. Merge RPC ─────────────────────────────────────────────────────
DROP FUNCTION IF EXISTS public.set_referral_suggestion_tier(UUID, UUID, TEXT);

CREATE FUNCTION public.set_referral_suggestion_tier(
  p_referral_id  UUID,
  p_clinician_id UUID,
  p_tier         TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_out JSONB;
BEGIN
  IF p_tier IS NOT NULL AND p_tier NOT IN ('accept', 'maybe', 'reject') THEN
    RAISE EXCEPTION 'invalid tier "%" — expected accept | maybe | reject', p_tier;
  END IF;

  UPDATE public.referrals
     SET suggestion_triage =
       CASE WHEN p_tier IS NULL
         THEN COALESCE(suggestion_triage, '{}'::jsonb) - p_clinician_id::text
         ELSE COALESCE(suggestion_triage, '{}'::jsonb)
              || jsonb_build_object(
                   p_clinician_id::text,
                   jsonb_build_object(
                     't',  p_tier,
                     'at', now(),
                     'by', COALESCE(auth.jwt() ->> 'email', 'unknown')
                   )
                 )
       END
   WHERE id = p_referral_id
   RETURNING suggestion_triage INTO v_out;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'referral % not found', p_referral_id;
  END IF;

  RETURN v_out;
END;
$$;

REVOKE ALL ON FUNCTION public.set_referral_suggestion_tier(UUID, UUID, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.set_referral_suggestion_tier(UUID, UUID, TEXT) TO authenticated;

COMMIT;

NOTIFY pgrst, 'reload schema';
