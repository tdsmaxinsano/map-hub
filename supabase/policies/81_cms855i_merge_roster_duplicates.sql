-- ════════════════════════════════════════════════════════════════════
-- 81 · CMS-855I enrollment — merge roster-request duplicates left by 80
--
-- Roster Review's 📄 Med B / ✓ actions create NAMELESS records linked to
-- the clinician (clinician_id set, first/last name blank — the name comes
-- from ID documents). Migration 80 matched existing records by NPI and
-- name only, so for a clinician who already had one of those nameless
-- records it INSERTED a second, named record — e.g. "Adam Ouyang" plus
-- "Adam Ouyang (roster)" on the ✅ Credentialed tab.
--
-- For each seeded (migration 80 NPI) record that is NOT roster-linked,
-- find a nameless record linked to the same-named roster clinician and
-- fold it into the seeded record:
--   • payload: the seeded record's values win; blanks are filled from the
--     nameless record; provider_notes from both are kept (joined).
--   • doc_slots: union (seeded wins on the same slot).
--   • clinician_id moves to the seeded record (Roster's Med B chip keeps
--     working), then the nameless record is deleted.
-- Data only. Idempotent — after one run there is nothing left to merge.
-- ════════════════════════════════════════════════════════════════════
BEGIN;

DO $$
DECLARE
  s       RECORD;
  r       RECORD;
  merged  JSONB;
  notes   TEXT;
  n       INT := 0;
BEGIN
  FOR s IN
    SELECT p.* FROM public.cms855i_providers p
    WHERE p.clinician_id IS NULL
      AND trim(p.first_name) <> '' AND trim(p.last_name) <> ''
      AND p.payload->>'npi' IN ('1174312953','1821671280','1578255188','1578706222','1023726668',
        '1548949001','1922732809','1518626274','1992841472','1790483527','1528207016',
        '1467669812','1700582541','1609176841')
  LOOP
    SELECT p.* INTO r
    FROM public.cms855i_providers p
    JOIN public.clinician_v2 c ON c.id = p.clinician_id
    WHERE p.id <> s.id
      AND trim(p.first_name) = '' AND trim(p.last_name) = ''
      AND regexp_replace(lower(trim(c.name)), '\s+(pt|pta|ot|ota|dpt|otr|cota|otr/l)$', '')
          = lower(trim(s.first_name) || ' ' || trim(s.last_name))
    LIMIT 1;
    IF NOT FOUND THEN CONTINUE; END IF;

    -- Seeded values win; fill blanks/missing keys from the nameless record.
    SELECT coalesce(jsonb_object_agg(e.key, e.value), '{}'::jsonb) INTO merged
    FROM jsonb_each(r.payload) e
    WHERE coalesce(s.payload->>e.key, '') = '';
    merged := merged || (SELECT coalesce(jsonb_object_agg(k.key, k.value), '{}'::jsonb)
                         FROM jsonb_each(s.payload) k WHERE coalesce(k.value #>> '{}', '') <> '');
    notes := concat_ws(E'\n',
      nullif(trim(coalesce(s.payload->>'provider_notes', '')), ''),
      nullif(trim(coalesce(r.payload->>'provider_notes', '')), ''));
    IF notes IS NOT NULL THEN merged := merged || jsonb_build_object('provider_notes', notes); END IF;

    DELETE FROM public.cms855i_providers WHERE id = r.id;
    UPDATE public.cms855i_providers SET
      clinician_id = r.clinician_id,
      payload      = merged,
      doc_slots    = coalesce(r.doc_slots, '{}'::jsonb) || coalesce(s.doc_slots, '{}'::jsonb),
      last_updated = now()
    WHERE id = s.id;

    RAISE NOTICE 'Merged roster record % into % % (%)', r.id, s.first_name, s.last_name, s.id;
    n := n + 1;
  END LOOP;
  RAISE NOTICE 'Roster duplicates merged: %', n;
END $$;

COMMIT;

-- Check: each seeded provider should now appear once, roster-linked when
-- the roster has them.
SELECT first_name, last_name, progress_status, payload->>'npi' AS npi,
       clinician_id IS NOT NULL AS roster_linked, payload->>'provider_notes' AS notes
FROM public.cms855i_providers
WHERE payload->>'npi' IN ('1174312953','1821671280','1578255188','1578706222','1023726668',
  '1548949001','1922732809','1518626274','1992841472','1790483527','1528207016',
  '1467669812','1700582541','1609176841')
ORDER BY last_name, first_name;
