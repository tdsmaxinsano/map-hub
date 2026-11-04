-- ════════════════════════════════════════════════════════════════════
-- 89 · Parking reimbursements (Finance → QB Tools → 🅿️ Parking)
--
-- Clinicians text/email parking receipts from patient visits. The
-- office pays the clinician (QB Check) and invoices the home-health
-- agency to recover it (QB Invoice PK#### — see the existing PK0022).
-- One row per receipt, mirroring the office tracking sheet:
-- Clinician · Date Received · Session Date · Payer(vendor) ·
-- Session # · Address · Patient · Amount · HH(agency).
--
-- tb_row_id links to therapy_boss_completed_service_import_rows when
-- the request matches an imported episode (patient + clinician + date
-- inside the episode window); referral_source on that row supplies the
-- agency automatically. Check/invoice exports stamp the two *_at
-- columns; a row is closed when both are set.
--
-- Receipt screenshots live in the PRIVATE parking-receipts bucket
-- (admin-only, mirrors the cms855i-docs posture) so the office can
-- download them to attach to the QB invoice email, as done today.
-- Admin-only RLS; the Finance page talks to the table directly.
-- Idempotent.
-- ════════════════════════════════════════════════════════════════════
BEGIN;

CREATE TABLE IF NOT EXISTS public.parking_reimbursements (
  id                 UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  clinician_id       UUID REFERENCES public.clinician_v2(id),
  clinician_name     TEXT NOT NULL,
  patient_name       TEXT,
  session_date       DATE,                      -- the parking / visit date
  date_received      DATE NOT NULL DEFAULT CURRENT_DATE,
  vendor             TEXT,                      -- ParkChicago / garage ("Payer" on the sheet)
  session_number     TEXT,                      -- receipt session / ticket #
  location           TEXT,                      -- parking address / zone
  amount             NUMERIC(10,2) NOT NULL CHECK (amount > 0),  -- receipt TOTAL (incl. fees)
  agency_name        TEXT,                      -- home-health agency to invoice ("HH")
  source             TEXT NOT NULL DEFAULT 'text' CHECK (source IN ('text','email','other')),
  notes              TEXT,
  receipt_path       TEXT,                      -- parking-receipts bucket object
  tb_matched         BOOLEAN NOT NULL DEFAULT FALSE,
  tb_row_id          UUID,
  check_exported_at  TIMESTAMPTZ,               -- QB Check batch stamp
  check_batch        TEXT,
  invoiced_at        TIMESTAMPTZ,               -- QB Invoice stamp
  invoice_no         TEXT,                      -- PK#### it landed on
  voided_at          TIMESTAMPTZ,               -- 🚫 excluded from exports, kept for audit
  void_reason        TEXT,
  created_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
  created_by         UUID,
  updated_at         TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS park_reimb_open_idx
  ON public.parking_reimbursements (check_exported_at, invoiced_at);
CREATE INDEX IF NOT EXISTS park_reimb_clin_idx
  ON public.parking_reimbursements (clinician_name);

-- updated_at trigger (same shape as migration 31)
CREATE OR REPLACE FUNCTION public.touch_parking_reimbursements()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN NEW.updated_at = now(); RETURN NEW; END $$;
DROP TRIGGER IF EXISTS trg_touch_parking_reimbursements ON public.parking_reimbursements;
CREATE TRIGGER trg_touch_parking_reimbursements
  BEFORE UPDATE ON public.parking_reimbursements
  FOR EACH ROW EXECUTE FUNCTION public.touch_parking_reimbursements();

ALTER TABLE public.parking_reimbursements ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "park_admin_read" ON public.parking_reimbursements;
CREATE POLICY "park_admin_read" ON public.parking_reimbursements
  FOR SELECT TO authenticated
  USING (EXISTS (SELECT 1 FROM public.user_roles
                 WHERE user_id = auth.uid() AND role = 'admin'));

DROP POLICY IF EXISTS "park_admin_write" ON public.parking_reimbursements;
CREATE POLICY "park_admin_write" ON public.parking_reimbursements
  FOR ALL TO authenticated
  USING (EXISTS (SELECT 1 FROM public.user_roles
                 WHERE user_id = auth.uid() AND role = 'admin'))
  WITH CHECK (EXISTS (SELECT 1 FROM public.user_roles
                      WHERE user_id = auth.uid() AND role = 'admin'));

-- ── Private receipts bucket + admin-only object policies ─────────────
INSERT INTO storage.buckets (id, name, public)
VALUES ('parking-receipts', 'parking-receipts', false)
ON CONFLICT (id) DO NOTHING;

DROP POLICY IF EXISTS "parkrcpt_admin_all" ON storage.objects;
CREATE POLICY "parkrcpt_admin_all" ON storage.objects
  FOR ALL TO authenticated
  USING (bucket_id = 'parking-receipts'
         AND EXISTS (SELECT 1 FROM public.user_roles
                     WHERE user_id = auth.uid() AND role = 'admin'))
  WITH CHECK (bucket_id = 'parking-receipts'
              AND EXISTS (SELECT 1 FROM public.user_roles
                          WHERE user_id = auth.uid() AND role = 'admin'));

NOTIFY pgrst, 'reload schema';

COMMIT;
