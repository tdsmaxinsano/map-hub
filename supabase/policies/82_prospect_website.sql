-- ════════════════════════════════════════════════════════════════════
-- 82 · Prospects: website column (requires migration 80)
--
-- agency_prospects gains a website URL, shown as a 🌐 link on the
-- prospect row and editable via the new ✏️ Edit prospect modal.
-- RLS already covers it (row policies from migration 80). Idempotent.
-- ════════════════════════════════════════════════════════════════════
BEGIN;

ALTER TABLE public.agency_prospects
  ADD COLUMN IF NOT EXISTS website TEXT;

NOTIFY pgrst, 'reload schema';

COMMIT;
