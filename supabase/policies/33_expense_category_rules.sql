-- Expense Category Rules (Chase Transaction Categorizer)
-- =====================================================================
-- Backs the new ② Expense Categorizer card in Finance → QB Tools.
-- One row per (category, keyword) mapping with a default deductible
-- percentage. The frontend matches Chase CSV expense rows against
-- these rules via case-insensitive substring search on the description
-- column. First match wins (rules are scanned in priority + insertion
-- order).
--
-- Rules are SHARED across all admins (per user direction) so as new
-- vendors / payees show up, anyone can add a keyword once and every
-- admin benefits on their next import. RLS: admin-only read + write.
--
-- Seed defaults match the Chase_Transaction_Categorizer_AI_Instructions
-- spec section "Main Requirements / 2. Categorize Transactions
-- Automatically" so the user can drop a CSV immediately after running
-- this migration and get reasonable categorization without any
-- manual rule entry.
--
-- Idempotent — safe to re-run. Seed inserts are guarded with ON
-- CONFLICT DO NOTHING so re-runs don't duplicate.

BEGIN;

-- ── 1. Table ──────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.expense_category_rules (
  id                    UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  category              TEXT NOT NULL,
  -- Display form of the keyword (e.g. "BCBS", "COSTCO") — what the
  -- user typed. Display preserved for UI; matching uses the
  -- normalized form below.
  keyword               TEXT NOT NULL,
  -- Lowercased + trimmed for case-insensitive substring matching.
  -- UNIQUE so we can't accidentally save the same keyword twice.
  keyword_normalized    TEXT NOT NULL UNIQUE,
  deductible_percent    NUMERIC(5,4) NOT NULL DEFAULT 1.0
                          CHECK (deductible_percent >= 0 AND deductible_percent <= 1),
  -- Some categories (Payroll, anything ambiguous) should be flagged
  -- for human review even when auto-categorized.
  review_flag_default   BOOLEAN NOT NULL DEFAULT FALSE,
  -- Lower priority value = higher precedence. Lets us put specific
  -- rules above generic ones if the keyword sets ever conflict.
  priority              INTEGER NOT NULL DEFAULT 100,
  -- Audit
  created_at            TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  created_by            UUID REFERENCES auth.users(id),
  updated_at            TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_by            UUID REFERENCES auth.users(id)
);

CREATE INDEX IF NOT EXISTS ecr_category_idx ON public.expense_category_rules (category);
CREATE INDEX IF NOT EXISTS ecr_priority_idx ON public.expense_category_rules (priority, category);

-- updated_at touch trigger
CREATE OR REPLACE FUNCTION public.ecr_touch_updated_at()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  NEW.updated_at := NOW();
  IF NEW.updated_by IS NULL THEN
    NEW.updated_by := auth.uid();
  END IF;
  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS ecr_touch_updated_at_trg ON public.expense_category_rules;
CREATE TRIGGER ecr_touch_updated_at_trg
  BEFORE INSERT OR UPDATE ON public.expense_category_rules
  FOR EACH ROW EXECUTE FUNCTION public.ecr_touch_updated_at();

-- ── 2. RLS — admin only ──────────────────────────────────────────
ALTER TABLE public.expense_category_rules ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "ecr_admin_read"  ON public.expense_category_rules;
DROP POLICY IF EXISTS "ecr_admin_write" ON public.expense_category_rules;

CREATE POLICY "ecr_admin_read" ON public.expense_category_rules
  FOR SELECT TO authenticated
  USING (EXISTS (SELECT 1 FROM public.user_roles ur
                 WHERE ur.user_id = auth.uid() AND ur.role = 'admin'));

CREATE POLICY "ecr_admin_write" ON public.expense_category_rules
  FOR ALL TO authenticated
  USING      (EXISTS (SELECT 1 FROM public.user_roles ur
                      WHERE ur.user_id = auth.uid() AND ur.role = 'admin'))
  WITH CHECK (EXISTS (SELECT 1 FROM public.user_roles ur
                      WHERE ur.user_id = auth.uid() AND ur.role = 'admin'));

-- ── 3. Normalizer (lowercase + trim) ────────────────────────────
CREATE OR REPLACE FUNCTION public.normalize_expense_keyword(kw TEXT)
RETURNS TEXT
LANGUAGE sql IMMUTABLE AS $$
  SELECT NULLIF(LOWER(TRIM(COALESCE(kw, ''))), '');
$$;

-- ── 4. RPC: list_expense_rules ────────────────────────────────────
CREATE OR REPLACE FUNCTION public.list_expense_rules()
RETURNS TABLE (
  id                  UUID,
  category            TEXT,
  keyword             TEXT,
  keyword_normalized  TEXT,
  deductible_percent  NUMERIC,
  review_flag_default BOOLEAN,
  priority            INTEGER,
  updated_at          TIMESTAMPTZ
)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM user_roles ur
                 WHERE ur.user_id = auth.uid() AND ur.role = 'admin') THEN
    RAISE EXCEPTION 'Only admin may list expense rules';
  END IF;

  RETURN QUERY
    SELECT
      r.id, r.category::TEXT, r.keyword::TEXT, r.keyword_normalized::TEXT,
      r.deductible_percent, r.review_flag_default, r.priority, r.updated_at
    FROM expense_category_rules r
    ORDER BY r.category, r.priority, r.keyword;
END $$;

REVOKE ALL ON FUNCTION public.list_expense_rules() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.list_expense_rules() TO authenticated;

-- ── 5. RPC: upsert_expense_rule ───────────────────────────────────
-- Upsert by (id) for edits or (keyword_normalized) for new entries.
-- If p_id is NULL → INSERT (or update existing row if the normalized
-- keyword already exists). If p_id given → UPDATE that specific row.
CREATE OR REPLACE FUNCTION public.upsert_expense_rule(
  p_id                  UUID,
  p_category            TEXT,
  p_keyword             TEXT,
  p_deductible_percent  NUMERIC,
  p_review_flag_default BOOLEAN DEFAULT FALSE,
  p_priority            INTEGER DEFAULT 100
)
RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  norm   TEXT;
  out_id UUID;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM user_roles ur
                 WHERE ur.user_id = auth.uid() AND ur.role = 'admin') THEN
    RAISE EXCEPTION 'Only admin may modify expense rules';
  END IF;
  IF p_category IS NULL OR TRIM(p_category) = '' THEN
    RAISE EXCEPTION 'category required';
  END IF;
  IF p_keyword IS NULL OR TRIM(p_keyword) = '' THEN
    RAISE EXCEPTION 'keyword required';
  END IF;
  IF p_deductible_percent IS NULL OR p_deductible_percent < 0 OR p_deductible_percent > 1 THEN
    RAISE EXCEPTION 'deductible_percent must be between 0 and 1';
  END IF;

  norm := normalize_expense_keyword(p_keyword);
  IF norm IS NULL THEN
    RAISE EXCEPTION 'normalized keyword is empty';
  END IF;

  IF p_id IS NULL THEN
    -- Insert new (or update existing by normalized keyword)
    INSERT INTO expense_category_rules (
      category, keyword, keyword_normalized,
      deductible_percent, review_flag_default, priority,
      created_by, updated_by
    ) VALUES (
      TRIM(p_category), TRIM(p_keyword), norm,
      p_deductible_percent, COALESCE(p_review_flag_default, FALSE),
      COALESCE(p_priority, 100),
      auth.uid(), auth.uid()
    )
    ON CONFLICT (keyword_normalized) DO UPDATE
      SET category            = EXCLUDED.category,
          keyword             = EXCLUDED.keyword,
          deductible_percent  = EXCLUDED.deductible_percent,
          review_flag_default = EXCLUDED.review_flag_default,
          priority            = EXCLUDED.priority,
          updated_by          = auth.uid()
    RETURNING id INTO out_id;
  ELSE
    -- Update existing by id (allows changing the keyword too)
    UPDATE expense_category_rules
    SET category            = TRIM(p_category),
        keyword             = TRIM(p_keyword),
        keyword_normalized  = norm,
        deductible_percent  = p_deductible_percent,
        review_flag_default = COALESCE(p_review_flag_default, FALSE),
        priority            = COALESCE(p_priority, 100),
        updated_by          = auth.uid()
    WHERE id = p_id
    RETURNING id INTO out_id;
    IF out_id IS NULL THEN
      RAISE EXCEPTION 'expense rule % not found', p_id;
    END IF;
  END IF;

  RETURN out_id;
END $$;

REVOKE ALL ON FUNCTION public.upsert_expense_rule(UUID, TEXT, TEXT, NUMERIC, BOOLEAN, INTEGER) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.upsert_expense_rule(UUID, TEXT, TEXT, NUMERIC, BOOLEAN, INTEGER) TO authenticated;

-- ── 6. RPC: delete_expense_rule ───────────────────────────────────
CREATE OR REPLACE FUNCTION public.delete_expense_rule(p_id UUID)
RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM user_roles ur
                 WHERE ur.user_id = auth.uid() AND ur.role = 'admin') THEN
    RAISE EXCEPTION 'Only admin may delete expense rules';
  END IF;

  DELETE FROM expense_category_rules WHERE id = p_id;
END $$;

REVOKE ALL ON FUNCTION public.delete_expense_rule(UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.delete_expense_rule(UUID) TO authenticated;

-- ── 7. Seed defaults ──────────────────────────────────────────────
-- Per the AI Instructions spec. ON CONFLICT DO NOTHING so re-running
-- this migration doesn't clobber user-edited rules.
INSERT INTO public.expense_category_rules (category, keyword, keyword_normalized, deductible_percent, review_flag_default, priority) VALUES
  -- Health Insurance (100%)
  ('Health Insurance',         'BCBS',              normalize_expense_keyword('BCBS'),              1.00, FALSE, 100),
  ('Health Insurance',         'BLUE CROSS',        normalize_expense_keyword('BLUE CROSS'),        1.00, FALSE, 100),
  ('Health Insurance',         'BLUE SHIELD',       normalize_expense_keyword('BLUE SHIELD'),       1.00, FALSE, 100),
  ('Health Insurance',         'HEALTH INSURANCE',  normalize_expense_keyword('HEALTH INSURANCE'),  1.00, FALSE, 100),
  ('Health Insurance',         'MARKETPLACE',       normalize_expense_keyword('MARKETPLACE'),       1.00, FALSE, 100),
  ('Health Insurance',         'DENTAL',            normalize_expense_keyword('DENTAL'),            1.00, FALSE, 100),
  ('Health Insurance',         'VISION',            normalize_expense_keyword('VISION'),            1.00, FALSE, 100),

  -- Advertising & Marketing (50% for retail/food, 100% for software/ads)
  ('Advertising & Marketing',  'COSTCO',            normalize_expense_keyword('COSTCO'),            0.50, FALSE, 100),
  ('Advertising & Marketing',  'JEWEL',             normalize_expense_keyword('JEWEL'),             0.50, FALSE, 100),
  ('Advertising & Marketing',  'WALMART',           normalize_expense_keyword('WALMART'),           0.50, FALSE, 100),
  ('Advertising & Marketing',  'TARGET',            normalize_expense_keyword('TARGET'),            0.50, FALSE, 100),
  ('Advertising & Marketing',  'MARIANO',           normalize_expense_keyword('MARIANO'),           0.50, FALSE, 100),
  ('Advertising & Marketing',  'ALDI',              normalize_expense_keyword('ALDI'),              0.50, FALSE, 100),
  ('Advertising & Marketing',  'DUNKIN',            normalize_expense_keyword('DUNKIN'),            0.50, FALSE, 100),
  ('Advertising & Marketing',  'STARBUCKS',         normalize_expense_keyword('STARBUCKS'),         0.50, FALSE, 100),
  ('Advertising & Marketing',  'DONUT',             normalize_expense_keyword('DONUT'),             0.50, FALSE, 100),
  ('Advertising & Marketing',  'COFFEE',            normalize_expense_keyword('COFFEE'),            0.50, FALSE, 100),
  ('Advertising & Marketing',  'CANVA',             normalize_expense_keyword('CANVA'),             1.00, FALSE, 100),
  ('Advertising & Marketing',  'META',              normalize_expense_keyword('META'),              1.00, FALSE, 100),
  ('Advertising & Marketing',  'FACEBOOK',          normalize_expense_keyword('FACEBOOK'),          1.00, FALSE, 100),
  ('Advertising & Marketing',  'GOOGLE ADS',        normalize_expense_keyword('GOOGLE ADS'),        1.00, FALSE, 90),
  ('Advertising & Marketing',  'WIX',               normalize_expense_keyword('WIX'),               1.00, FALSE, 100),
  ('Advertising & Marketing',  'PROWEAVER',         normalize_expense_keyword('PROWEAVER'),         1.00, FALSE, 100),
  ('Advertising & Marketing',  'INDEED',            normalize_expense_keyword('INDEED'),            1.00, FALSE, 100),

  -- Meals / Client Meetings (50%)
  ('Meals / Client Meetings',  'RESTAURANT',        normalize_expense_keyword('RESTAURANT'),        0.50, FALSE, 100),
  ('Meals / Client Meetings',  'GIORDANO',          normalize_expense_keyword('GIORDANO'),          0.50, FALSE, 100),
  ('Meals / Client Meetings',  'CHEESECAKE',        normalize_expense_keyword('CHEESECAKE'),        0.50, FALSE, 100),
  ('Meals / Client Meetings',  'PIZZA',             normalize_expense_keyword('PIZZA'),             0.50, FALSE, 100),
  ('Meals / Client Meetings',  'PANERA',            normalize_expense_keyword('PANERA'),            0.50, FALSE, 100),
  ('Meals / Client Meetings',  'CHIPOTLE',          normalize_expense_keyword('CHIPOTLE'),          0.50, FALSE, 100),
  ('Meals / Client Meetings',  'MCDONALD',          normalize_expense_keyword('MCDONALD'),          0.50, FALSE, 100),
  ('Meals / Client Meetings',  'TACO',              normalize_expense_keyword('TACO'),              0.50, FALSE, 100),
  ('Meals / Client Meetings',  'SUBWAY',            normalize_expense_keyword('SUBWAY'),            0.50, FALSE, 100),
  ('Meals / Client Meetings',  'CAFE',              normalize_expense_keyword('CAFE'),              0.50, FALSE, 100),

  -- Auto / Travel (75% for fuel, 100% for tolls/parking)
  ('Auto / Travel',            'GAS',               normalize_expense_keyword('GAS'),               0.75, FALSE, 100),
  ('Auto / Travel',            'FUEL',              normalize_expense_keyword('FUEL'),              0.75, FALSE, 100),
  ('Auto / Travel',            'SHELL',             normalize_expense_keyword('SHELL'),             0.75, FALSE, 100),
  ('Auto / Travel',            'BP',                normalize_expense_keyword('BP'),                0.75, FALSE, 100),
  ('Auto / Travel',            'MOBIL',             normalize_expense_keyword('MOBIL'),             0.75, FALSE, 100),
  ('Auto / Travel',            'EXXON',             normalize_expense_keyword('EXXON'),             0.75, FALSE, 100),
  ('Auto / Travel',            'CITGO',             normalize_expense_keyword('CITGO'),             0.75, FALSE, 100),
  ('Auto / Travel',            'SPEEDWAY',          normalize_expense_keyword('SPEEDWAY'),          0.75, FALSE, 100),
  ('Auto / Travel',            'PARKING',           normalize_expense_keyword('PARKING'),           1.00, FALSE, 100),
  ('Auto / Travel',            'TOLL',              normalize_expense_keyword('TOLL'),              1.00, FALSE, 100),
  ('Auto / Travel',            'I-PASS',            normalize_expense_keyword('I-PASS'),            1.00, FALSE, 100),
  ('Auto / Travel',            'AUTO',              normalize_expense_keyword('AUTO'),              0.75, TRUE,  120),
  ('Auto / Travel',            'CAR WASH',          normalize_expense_keyword('CAR WASH'),          0.75, FALSE, 100),
  ('Auto / Travel',            'OIL CHANGE',        normalize_expense_keyword('OIL CHANGE'),        0.75, FALSE, 100),
  ('Auto / Travel',            'REPAIR',            normalize_expense_keyword('REPAIR'),            0.75, TRUE,  120),

  -- Office / Software / Technology (100%)
  ('Office / Software',        'APPLE',             normalize_expense_keyword('APPLE'),             1.00, FALSE, 100),
  ('Office / Software',        'MICROSOFT',         normalize_expense_keyword('MICROSOFT'),         1.00, FALSE, 100),
  ('Office / Software',        'ADOBE',             normalize_expense_keyword('ADOBE'),             1.00, FALSE, 100),
  ('Office / Software',        'GOOGLE',            normalize_expense_keyword('GOOGLE'),            1.00, FALSE, 110),
  ('Office / Software',        'QUICKBOOKS',        normalize_expense_keyword('QUICKBOOKS'),        1.00, FALSE, 100),
  ('Office / Software',        'INTUIT',            normalize_expense_keyword('INTUIT'),            1.00, FALSE, 100),
  ('Office / Software',        'RINGCENTRAL',       normalize_expense_keyword('RINGCENTRAL'),       1.00, FALSE, 100),
  ('Office / Software',        'ZOOM',              normalize_expense_keyword('ZOOM'),              1.00, FALSE, 100),
  ('Office / Software',        'DROPBOX',           normalize_expense_keyword('DROPBOX'),           1.00, FALSE, 100),
  ('Office / Software',        'OFFICE DEPOT',      normalize_expense_keyword('OFFICE DEPOT'),      1.00, FALSE, 100),
  ('Office / Software',        'STAPLES',           normalize_expense_keyword('STAPLES'),           1.00, FALSE, 100),
  ('Office / Software',        'AMAZON',            normalize_expense_keyword('AMAZON'),            1.00, TRUE,  110),
  ('Office / Software',        'BEST BUY',          normalize_expense_keyword('BEST BUY'),          1.00, FALSE, 100),

  -- Utilities / Phone / Internet (100% or 50% if mixed-use — default 100, flag for review)
  ('Utilities / Phone / Internet', 'COMCAST',       normalize_expense_keyword('COMCAST'),           1.00, FALSE, 100),
  ('Utilities / Phone / Internet', 'XFINITY',       normalize_expense_keyword('XFINITY'),           1.00, FALSE, 100),
  ('Utilities / Phone / Internet', 'AT&T',          normalize_expense_keyword('AT&T'),              1.00, TRUE,  100),
  ('Utilities / Phone / Internet', 'VERIZON',       normalize_expense_keyword('VERIZON'),           1.00, TRUE,  100),
  ('Utilities / Phone / Internet', 'T-MOBILE',      normalize_expense_keyword('T-MOBILE'),          1.00, TRUE,  100),
  ('Utilities / Phone / Internet', 'NICOR',         normalize_expense_keyword('NICOR'),             1.00, FALSE, 100),
  ('Utilities / Phone / Internet', 'COMED',         normalize_expense_keyword('COMED'),             1.00, FALSE, 100),
  ('Utilities / Phone / Internet', 'ELECTRIC',      normalize_expense_keyword('ELECTRIC'),          1.00, FALSE, 100),
  ('Utilities / Phone / Internet', 'INTERNET',      normalize_expense_keyword('INTERNET'),          1.00, FALSE, 100),
  ('Utilities / Phone / Internet', 'PHONE',         normalize_expense_keyword('PHONE'),             1.00, TRUE,  120),

  -- Contractor / Payroll / Staffing (100% — always flag for review)
  ('Contractor / Payroll',     'ZELLE',             normalize_expense_keyword('ZELLE'),             1.00, TRUE, 100),
  ('Contractor / Payroll',     'PAYROLL',           normalize_expense_keyword('PAYROLL'),           1.00, TRUE, 100),
  ('Contractor / Payroll',     'ADP',               normalize_expense_keyword('ADP'),               1.00, TRUE, 100),
  ('Contractor / Payroll',     'GUSTO',             normalize_expense_keyword('GUSTO'),             1.00, TRUE, 100),
  ('Contractor / Payroll',     'CHECK',             normalize_expense_keyword('CHECK'),             1.00, TRUE, 150),
  ('Contractor / Payroll',     'DIRECT DEPOSIT',    normalize_expense_keyword('DIRECT DEPOSIT'),    1.00, TRUE, 100),
  ('Contractor / Payroll',     'CONTRACTOR',        normalize_expense_keyword('CONTRACTOR'),        1.00, TRUE, 100),
  ('Contractor / Payroll',     'THERAPIST',         normalize_expense_keyword('THERAPIST'),         1.00, TRUE, 100),
  ('Contractor / Payroll',     'STAFFING',          normalize_expense_keyword('STAFFING'),          1.00, TRUE, 100),

  -- Bank Fees / Processing Fees (100%)
  ('Bank Fees / Processing',   'FEE',               normalize_expense_keyword('FEE'),               1.00, FALSE, 130),
  ('Bank Fees / Processing',   'SERVICE CHARGE',    normalize_expense_keyword('SERVICE CHARGE'),    1.00, FALSE, 100),
  ('Bank Fees / Processing',   'RTP',               normalize_expense_keyword('RTP'),               1.00, FALSE, 100),
  ('Bank Fees / Processing',   'SAME DAY',          normalize_expense_keyword('SAME DAY'),          1.00, FALSE, 100),
  ('Bank Fees / Processing',   'WIRE FEE',          normalize_expense_keyword('WIRE FEE'),          1.00, FALSE, 90),
  ('Bank Fees / Processing',   'ACH FEE',           normalize_expense_keyword('ACH FEE'),           1.00, FALSE, 90),
  ('Bank Fees / Processing',   'QUICKBOOKS PAYMENTS', normalize_expense_keyword('QUICKBOOKS PAYMENTS'), 1.00, FALSE, 90),
  ('Bank Fees / Processing',   'CARD PROCESSING',   normalize_expense_keyword('CARD PROCESSING'),   1.00, FALSE, 90)

ON CONFLICT (keyword_normalized) DO NOTHING;

COMMIT;

NOTIFY pgrst, 'reload schema';
