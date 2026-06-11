-- Office staff — pay categories (Wise hourly / hourly→QB Bill / salary DD)
-- =====================================================================
-- Background: staff_config.pay_type ('philippines' | 'us') is too coarse.
-- Real office payroll has THREE arrangements:
--   • wise_hourly — PH staff: hours × hourly_rate, paid via the Wise
--     batch the admin sends from the Time Tracker (existing behavior).
--   • hourly_bill — US hourly staff (e.g. office clerk): the portal
--     submits HOURS; accounting computes the pay in QuickBooks as a Bill
--     (Contract Labor:Office Clerk @ their real rate). Portal shows
--     hours (+ amount when hourly_rate is set to match QB).
--   • salary_dd  — US salaried staff: a fixed amount per pay period,
--     paid by direct deposit. No more manual hour-entry games to make
--     the math come out — the salary IS the number.
--
-- pay_type stays (it drives Wise-identity fields + legacy filters); the
-- Time Tracker derives it from the category on save (wise_hourly →
-- 'philippines', otherwise 'us'). pay_category is the source of truth
-- for the pay MATH in both the Time Tracker Pay Period view and the
-- Finance payroll-run office block.
--
-- RLS: staff_config is already writable by the admin Settings UI via
-- direct .update() (Phase 1 authenticated policy) — the new columns
-- ride the same path. Additive + idempotent.

BEGIN;

-- ── 1. pay_category ────────────────────────────────────────────────
ALTER TABLE public.staff_config
  ADD COLUMN IF NOT EXISTS pay_category TEXT NOT NULL DEFAULT 'wise_hourly';

ALTER TABLE public.staff_config
  DROP CONSTRAINT IF EXISTS staff_config_pay_category_check;
ALTER TABLE public.staff_config
  ADD CONSTRAINT staff_config_pay_category_check
  CHECK (pay_category IN ('wise_hourly', 'hourly_bill', 'salary_dd'));

-- ── 2. salary_per_period (used only when pay_category = 'salary_dd') ─
ALTER TABLE public.staff_config
  ADD COLUMN IF NOT EXISTS salary_per_period NUMERIC(10,2) NOT NULL DEFAULT 0;

ALTER TABLE public.staff_config
  DROP CONSTRAINT IF EXISTS staff_config_salary_per_period_check;
ALTER TABLE public.staff_config
  ADD CONSTRAINT staff_config_salary_per_period_check
  CHECK (salary_per_period >= 0);

COMMENT ON COLUMN public.staff_config.pay_category IS
  'wise_hourly (PH, hours×rate via Wise) | hourly_bill (US, hours submitted — accounting computes in QB) | salary_dd (US, fixed salary_per_period via direct deposit)';
COMMENT ON COLUMN public.staff_config.salary_per_period IS
  'Fixed USD pay per bi-weekly period. Only meaningful when pay_category = salary_dd.';

-- ── 3. One-shot backfill ───────────────────────────────────────────
-- US staff start as hourly_bill (admin flips the salaried ones to
-- salary_dd in Time Tracker → Settings). Only touches rows still at
-- the column default so re-running never undoes an admin's choice.
UPDATE public.staff_config
   SET pay_category = 'hourly_bill'
 WHERE pay_category = 'wise_hourly'
   AND COALESCE(pay_type, 'philippines') = 'us';

COMMIT;

NOTIFY pgrst, 'reload schema';
