-- ════════════════════════════════════════════════════════════════════
-- 80 · CMS-855I enrollment — one-time load of CREDENTIALED providers
--
-- Source: the PECOS "Reassignments Report" (receiving Medicare ID
-- F100954559 = Dependable Care). Only APPROVED rows are loaded —
-- APPROVED = actively reassigning benefits to us. DEACTIVATED rows
-- are deliberately skipped.
--
-- For each row:
--   • Existing provider (match by payload npi, else first+last name)
--       → progress_status 'Credentialed', pecos_status 'Completed';
--         payload npi / enrollment_effective_date filled only if empty;
--         payload pecos_medicare_id always set.
--   • No match → INSERT a new credentialed record.
--   • Not yet roster-linked → link to the clinician_v2 row with the same
--     name (trailing PT/PTA/OT/OTA/... stripped), only if no other record
--     already holds that clinician (one record per clinician — mig 71).
--     New records take their discipline from that roster row (default PT).
--
-- Credentialed records move to the ✅ Credentialed tab in enrollment.html
-- (out of the Form Filler pull-down + Progress board).
--
-- Data only, no schema change. Idempotent — re-running just re-applies
-- the same values. Requires migrations 69 + 71.
-- ════════════════════════════════════════════════════════════════════
BEGIN;

DO $$
DECLARE
  r          RECORD;
  pid        UUID;
  cid        UUID;
  cdisc      TEXT;
  disc       TEXT;
  n_matched  INT := 0;
  n_inserted INT := 0;
  n_linked   INT := 0;
BEGIN
  FOR r IN
    SELECT * FROM (VALUES
      -- first,       mi,  last,        npi,          medicare_id,  effective,    disc override
      ('Charles',   'C', 'Buscano',   '1174312953', 'F401323078', '10/01/2025', NULL),
      ('April',     'V', 'Cabrera',   '1821671280', 'F401314732', '08/18/2025', NULL),
      ('Deborah',   'J', 'Collins',   '1578255188', 'F401444239', '07/29/2026', NULL),
      ('Farrah',    'J', 'De Veyra',  '1578706222', 'F400956350', '12/01/2022', NULL),
      ('Rafael',    'V', 'De Veyra',  '1023726668', 'F401002319', '05/16/2023', NULL),
      ('Glenn',     '',  'Gayondato', '1548949001', 'F400993329', '06/24/2023', NULL),
      ('Charmaine', 'I', 'Juario',    '1922732809', 'F401143516', '08/07/2024', NULL),
      ('Jordan',    'B', 'Juralbal',  '1518626274', 'F400956151', '12/01/2022', NULL),
      ('Victorya',  '',  'Korobov',   '1992841472', 'F401031852', '10/17/2023', 'OT'),
      ('Adam',      '',  'Ouyang',    '1790483527', 'F400982372', '05/31/2023', NULL),
      ('Gina',      'M', 'Pelehac',   '1528207016', 'F400971342', '05/11/2023', NULL),
      ('Basma',     'K', 'Rafael',    '1467669812', 'F400971487', '05/11/2023', NULL),
      ('Joseph',    '',  'Suezo',     '1700582541', 'F401115284', '05/06/2024', NULL),
      ('Danielle',  'C', 'Whaley',    '1609176841', 'F401062026', '12/27/2023', NULL)
    ) AS v(first_name, mi, last_name, npi, medicare_id, effective, disc_override)
  LOOP
    -- Roster match by name (one record per clinician).
    SELECT c.id, upper(coalesce(c.discipline, '')) INTO cid, cdisc
    FROM public.clinician_v2 c
    WHERE regexp_replace(lower(trim(c.name)), '\s+(pt|pta|ot|ota|dpt|otr|cota|otr/l)$', '')
          = lower(r.first_name || ' ' || r.last_name)
    LIMIT 1;
    disc := coalesce(r.disc_override,
                     CASE WHEN cdisc LIKE 'OT%' OR cdisc = 'COTA' THEN 'OT' ELSE 'PT' END);

    -- Existing provider: NPI first, then name.
    SELECT p.id INTO pid FROM public.cms855i_providers p
    WHERE p.payload->>'npi' = r.npi LIMIT 1;
    IF pid IS NULL THEN
      SELECT p.id INTO pid FROM public.cms855i_providers p
      WHERE lower(trim(p.first_name)) = lower(r.first_name)
        AND lower(trim(p.last_name))  = lower(r.last_name)
      LIMIT 1;
    END IF;

    IF pid IS NOT NULL THEN
      UPDATE public.cms855i_providers p SET
        progress_status = 'Credentialed',
        pecos_status    = 'Completed',
        payload = p.payload
          || jsonb_build_object('progress_status', 'Credentialed', 'pecos_status', 'Completed',
                                'pecos_medicare_id', r.medicare_id)
          || CASE WHEN coalesce(p.payload->>'npi', '') = ''
                  THEN jsonb_build_object('npi', r.npi) ELSE '{}'::jsonb END
          || CASE WHEN coalesce(p.payload->>'enrollment_effective_date', '') = ''
                  THEN jsonb_build_object('enrollment_effective_date', r.effective) ELSE '{}'::jsonb END,
        last_updated = now()
      WHERE p.id = pid;
      n_matched := n_matched + 1;
    ELSE
      INSERT INTO public.cms855i_providers
        (first_name, last_name, discipline, progress_status, pecos_status, payload)
      VALUES
        (r.first_name, r.last_name, disc, 'Credentialed', 'Completed',
         jsonb_build_object(
           'first_name', r.first_name, 'middle_initial', r.mi, 'last_name', r.last_name,
           'printed_first_name', r.first_name, 'printed_middle_initial', r.mi, 'printed_last_name', r.last_name,
           'discipline', disc, 'progress_status', 'Credentialed', 'pecos_status', 'Completed',
           'npi', r.npi, 'pecos_medicare_id', r.medicare_id,
           'enrollment_effective_date', r.effective))
      RETURNING id INTO pid;
      n_inserted := n_inserted + 1;
    END IF;

    -- Korobov: keep the PT-in-error history visible.
    IF r.last_name = 'Korobov' THEN
      UPDATE public.cms855i_providers p SET
        discipline = 'OT',
        payload = p.payload || jsonb_build_object('discipline', 'OT')
          || CASE WHEN coalesce(p.payload->>'provider_notes', '') = ''
                  THEN jsonb_build_object('provider_notes',
                    'PECOS: earlier PT reassignments (F400984834) were credentialed in error and deactivated — re-applied as OT.')
                  ELSE '{}'::jsonb END
      WHERE p.id = pid;
    END IF;

    -- Roster link (only if unlinked and the clinician is free).
    IF cid IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM public.cms855i_providers x WHERE x.clinician_id = cid AND x.id <> pid) THEN
      UPDATE public.cms855i_providers SET clinician_id = cid
      WHERE id = pid AND clinician_id IS NULL;
      IF FOUND THEN n_linked := n_linked + 1; END IF;
    END IF;

    pid := NULL; cid := NULL; cdisc := NULL;
  END LOOP;

  RAISE NOTICE 'Credentialed seed: % matched existing, % inserted, % newly roster-linked',
    n_matched, n_inserted, n_linked;
END $$;

COMMIT;

-- What it did (one row per loaded provider):
SELECT first_name, last_name, discipline, progress_status, pecos_status,
       payload->>'npi' AS npi, payload->>'pecos_medicare_id' AS medicare_id,
       payload->>'enrollment_effective_date' AS effective,
       clinician_id IS NOT NULL AS roster_linked
FROM public.cms855i_providers
WHERE payload->>'npi' IN ('1174312953','1821671280','1578255188','1578706222','1023726668',
  '1548949001','1922732809','1518626274','1992841472','1790483527','1528207016',
  '1467669812','1700582541','1609176841')
ORDER BY last_name, first_name;
