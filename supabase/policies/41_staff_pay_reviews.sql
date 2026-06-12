-- Office staff — reviews & raises history (Time Tracker → Settings)
-- =====================================================================
-- Tracks every raise (old → new pay value) and performance review per
-- office staff member, with an optional uploaded review document.
--
-- Entry kinds:
--   • raise  — a pay change. pay_field says WHICH value changed
--     (hourly_rate for wise_hourly / hourly_bill staff,
--      salary_per_period for salary_dd staff — migration 40 categories).
--     old_value/new_value capture the before/after for the history.
--     May also carry a review doc (review-with-raise is common).
--   • review — a review on file with no pay change (doc and/or note).
--
-- Raises recorded through the Settings panel ALSO update staff_config
-- (client-side), so the history and the live rate never drift. Plain
-- rate edits via the Settings Save button are auto-logged as raises by
-- the client so the history stays complete even when the admin skips
-- the panel.
--
-- RLS: admin-only EVERYTHING — this is HR data (pay history + review
-- docs). Staff must not read each other's (or their own) entries here.
-- The review-docs bucket mirrors the vdr-reports private posture.
-- Additive + idempotent.

BEGIN;

-- ── 1. Table ───────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.staff_pay_reviews (
  id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id        UUID NOT NULL,                -- staff_config.user_id
  kind           TEXT NOT NULL DEFAULT 'raise'
                   CHECK (kind IN ('raise', 'review')),
  effective_date DATE NOT NULL DEFAULT CURRENT_DATE,
  pay_field      TEXT CHECK (pay_field IS NULL OR pay_field IN ('hourly_rate', 'salary_per_period')),
  old_value      NUMERIC(10,2),
  new_value      NUMERIC(10,2) CHECK (new_value IS NULL OR new_value >= 0),
  note           TEXT,
  doc_path       TEXT,                         -- storage path in staff-review-docs (nullable)
  created_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
  created_by     UUID
);

CREATE INDEX IF NOT EXISTS idx_staff_pay_reviews_user
  ON public.staff_pay_reviews (user_id, effective_date DESC);

ALTER TABLE public.staff_pay_reviews ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "staff_pay_reviews_admin_all" ON public.staff_pay_reviews;
CREATE POLICY "staff_pay_reviews_admin_all" ON public.staff_pay_reviews
  FOR ALL TO authenticated
  USING     (EXISTS (SELECT 1 FROM public.user_roles WHERE user_id = auth.uid() AND role = 'admin'))
  WITH CHECK (EXISTS (SELECT 1 FROM public.user_roles WHERE user_id = auth.uid() AND role = 'admin'));

-- ── 2. Storage bucket: staff-review-docs (private, admin-only) ─────
INSERT INTO storage.buckets (id, name, public)
VALUES ('staff-review-docs', 'staff-review-docs', false)
ON CONFLICT (id) DO NOTHING;

DROP POLICY IF EXISTS "staff_review_docs_admin_read"  ON storage.objects;
DROP POLICY IF EXISTS "staff_review_docs_admin_write" ON storage.objects;

CREATE POLICY "staff_review_docs_admin_read" ON storage.objects
  FOR SELECT TO authenticated
  USING (bucket_id = 'staff-review-docs'
         AND EXISTS (SELECT 1 FROM public.user_roles WHERE user_id = auth.uid() AND role = 'admin'));

CREATE POLICY "staff_review_docs_admin_write" ON storage.objects
  FOR ALL TO authenticated
  USING (bucket_id = 'staff-review-docs'
         AND EXISTS (SELECT 1 FROM public.user_roles WHERE user_id = auth.uid() AND role = 'admin'))
  WITH CHECK (bucket_id = 'staff-review-docs'
              AND EXISTS (SELECT 1 FROM public.user_roles WHERE user_id = auth.uid() AND role = 'admin'));

COMMIT;

NOTIFY pgrst, 'reload schema';
