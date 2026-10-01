-- ════════════════════════════════════════════════════════════════════
-- 71 · CMS-855I enrollment — link records to roster clinicians
--
-- Roster Review's "📄 Med B" send action creates a credentialing
-- request in cms855i_providers WITHOUT copying the clinician's name
-- (names typed into TB can be wrong — the packet name comes from the
-- verified ID documents). With no name on the record, duplicate
-- detection and the roster's "already sent" chip need a hard link:
-- this nullable clinician_id column (= clinician_v2.id).
--
-- Hand-created and backup-imported providers keep clinician_id NULL —
-- fully backward compatible. Idempotent. Run from the SQL editor
-- BEFORE deploying the matching client (the roster insert writes it).
-- ════════════════════════════════════════════════════════════════════
BEGIN;

ALTER TABLE public.cms855i_providers
  ADD COLUMN IF NOT EXISTS clinician_id UUID;

CREATE INDEX IF NOT EXISTS idx_cms855i_providers_clinician
  ON public.cms855i_providers (clinician_id)
  WHERE clinician_id IS NOT NULL;

NOTIFY pgrst, 'reload schema';

COMMIT;
