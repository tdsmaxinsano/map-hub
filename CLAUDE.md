# DependableCare Portal — Project Index

This is the master reference for the DependableCare internal staffing portal. Always read this file first, then read the specific CLAUDE file for the area you are working on.

---

## Project Structure

All files are standalone HTML/CSS/JS — no framework, no build step. They share the same Supabase project and Mapbox token.

| File | Purpose | Reference Doc |
|---|---|---|
| `clinician-map.html` | Main map dashboard — clinician locations, filters, referral overlay, AI assistant (~24,000+ lines) | `CLAUDE-map.md` |
| `referrals.html` | Referral board — table view, contacts, audit, new referral form | `CLAUDE-referrals.md` |
| `time-tracker.html` | Time tracking — clock in/out, pay periods, approvals, HUD | `CLAUDE-timetracker.md` |
| `compliance.html` | **Compliance Hub** with selectable trackers. Landing screen has two tiles: 📊 **Frequency Compliance** (visit-frequency tracking — active queue + resolved log, TB Create-bills HTML import) and ✅ **Evaluation Compliance** (TB Active Services + Patient List driven — categorized queue grouped by Issues/Hold/Re-Eval/No Sched/Scheduled-Late/To Sync/Completed/Assigned, color-coded by sync status: 🟢 synced / 🟡 eval done not synced / ⚪ no evaluation / ⬜ cancelled-term-returned). URL-driven view state (`?view=hub|frequency|evaluation`). Evaluation rows carry **non-editable `patient_id` + `referral_id` anchors** from TB so future cross-report joins (Patient Visits, Documented Procedures, AR Aging) are trivial. Inline per-row editing of category / sync status / notes (debounced, surgical updates). **Two-file import**: TB Active Services CSV + Patient List XLSX (SheetJS), joined client-side on Last+First+DOB+Referral date, upserts on (patient_id, referral_id). Auto-promotes rows to Hold/Hospital when TB has a hold flag set. Status Notes cell carries 4 stacked lines: editable user note + 3 read-only collapsible TB references (Episode instructions, Service protocol, Hold details). Preserves user-edited columns across re-imports. | (this file + comments in compliance.html) |
| `kanban.html` | Portal-wide kanban task board — multiple boards, SLAs, drag/drop, admin board management, staff profiles | `CLAUDE-kanban.md` |
| `roster-review.html` | **Bulk clinician editor for HR / coordinator review sessions.** Sticky thead + sticky Name column for big-table scrolling. Inline pause editor under each clinician's name when status=Paused (dropdown: Personal / Sick / Vacation / Other-with-text). Status pill + discipline pill stacked under each name for at-a-glance context. Performance metrics (Avg Sync Days / Avg Visits/Run / Avg Visit Time from VDR aggregates) shown directly after Status. **EMR chips are click-to-toggle** (Strata / TherapyBoss / Axxess / Kinnser — writes to same `emr_capabilities` JSONB the map reads). Restrictions opens a drawer with roster-only typeahead (agencies + clinicians; no free-text). Notes drawer. **Phone & Email read-only** with 🔒 indicator (TB is source of truth). **Emergency Contact** column (name / phone / relationship) with drawer editor — managed here since TB doesn't track it. ✓ Reviewed checkbox stamps `last_reviewed_at`/`last_reviewed_by`. Filters: status / discipline / "Need Review" / "Returning soon" / "Paused 30d+". Multi-select bulk actions + CSV export. Surgical EMR toggle keeps scroll position locked; other re-renders save/restore scroll + focus. Admin + Editor write access. | (this file + comments in roster-review.html) |
| `finance.html` | **Admin-only Finance area** with sub-views: Payroll (office-staff summary linking to Time Tracker + 🗓️ **Clinician Payroll Calendar** — yearly bi-weekly Sun→Sat periods, pay date = period_end + 16 days = Monday, anchor 2025-12-14, with print + CSV download + year nav) and **Billing**. Billing has 4 cards: ① **VDR Runner** ingests a `Create bills.xlsx` from TherapyBoss in the browser (SheetJS), flags discrepancies (OutOfRange / ShortAndBillable / MissedVisit / EvalTimeAlert), shows inline stats + Chart.js charts + tabbed discrepancy tables, generates a downloadable multi-sheet XLSX (ExcelJS); ② **Preview** (auto-shown after a run); ③ **History & Trends** persists every saved run to `vdr_runs` + `vdr_clinician_metrics` + `vdr_payer_metrics` with the report XLSX in `vdr-reports` bucket, history table with payroll-date markers (bi-weekly Wed before 2024-10-17, Thu after), **📊 View** button rebuilds the inline preview from the stored `prepared_rows` JSONB; ④ **Invoice Converter (IIF)** drag-drops a raw QuickBooks IIF, strips 11 cruft columns + filters TAXABLE/negative rows + renames headers + substitutes `Medicare → Medicare Part B.`, downloads cleaned `.iif` ready for SaaSant → QB upload (port of the user's local Python script). Two-layer admin gate (shell tab + page-level). | (this file + comments in finance.html) |
| `chat-widget.js` | Shared team-chat widget — included on every portal page; old-school single-channel team chat with presence + sound + tab-flash | `CLAUDE-kanban.md` (chat section) |
| `index.html` | **Portal shell** — owns the login/signup/forgot-password screen, header tabs, and 5 lazy-loaded iframes (one per tool). Home pane is a stats dashboard. State preserves across tabs. | (this file + comments in index.html) |

**Iframe shell (May 2026):** `index.html` is now an iframe shell instead of a simple redirect. The header hosts 6 tabs (🏠 Home · 🗺️ Map · 📋 Referrals · ⏱️ Time · ✅ Compliance · 🗂️ Kanban). Each tool tab is an `<iframe>` whose `src` is set lazily on first click. Subsequent clicks just toggle `hidden`, so the iframe's state (map zoom, kanban board, scroll, filters) is preserved. URL is `?tab=<id>` and updates via `history.pushState`; back/forward works natively. Exposes `window.shellSwitchTab(tabId, queryString)` so tools (in iframes) can call up to the shell to cross-navigate without losing sibling state.

**Per-tool iframe-detection:** Each tool HTML has a tiny script in `<head>` that adds `html.in-iframe-shell` when `window.self !== window.top`. CSS rules then hide each tool's duplicate chrome (portal nav strip, brand, user chip, sign-out) when running inside the shell. Tools accessed via direct URL still show their full header — backward compatible.

**Portal nav strip** (🏠 Home / 🗺️ Map / 📋 Referrals / ⏱️ Time / ✅ Compliance / 🗂️ Kanban / 📋 Roster / 💰 Finance) is the fallback navigation when a tool is loaded standalone. 🏠 Home is always first and links back to `index.html` (the shell's Home dashboard pane). 💰 Finance is admin-only-revealed. Uses real `<a href>` links so Ctrl/Cmd+click → new tab works for free. All pages use `localStorage` auth → SSO across the portal, no re-login when switching tabs.

---

## Shared Credentials

### Supabase
- **URL:** `https://jpemlcuxjvynlbeygukb.supabase.co`
- **Project ref:** `jpemlcuxjvynlbeygukb`
- **Anon key:** hardcoded in each file (search `supabaseKey`)
- **Auth:** `localStorage`-based in **all** files (clinician-map.html switched from `sessionStorage` → `localStorage` in May 2026 so sessions survive tab closes / browser restarts; required for the upcoming RLS rollout to not break first-time logins on a fresh browser)
- **RLS:** Phase 1 ON (May 2026, applied via `01_phase1_enable_rls.sql`); 23 core tables locked to `authenticated`-only. Rollback available at `01_phase1_rollback.sql` if needed.
- **Self-service signup + password reset:** the shell login screen handles 4 modes — Sign In · Sign Up · Forgot Password · Set New Password. Forgot triggers `db.auth.resetPasswordForEmail` with `redirectTo = origin + pathname` so the recovery link returns to the shell. Recovery is detected via the URL hash captured **before** Supabase init (race-condition-proof), and `inPasswordRecovery` suppresses Supabase's auto-`SIGNED_IN` event so users actually get to choose a new password before being logged in.

### Supabase Edge Functions
| Function | Purpose | Secrets used |
|---|---|---|
| `send-reactivation-email` | Emails hiring manager when staff requests reactivation of an Inactive clinician | `SENDGRID_API_KEY`, `SENDGRID_FROM_EMAIL`, `HIRING_MANAGER_EMAIL` |
| `send-import-report` | After successful Sync Update or ZIP coverage import, emails change report to logged-in user (CC list optional) | `SENDGRID_API_KEY`, `SENDGRID_FROM_EMAIL`, `IMPORT_REPORT_CC_EMAIL` (optional, comma-separated) |
| `tb-scan-image` | Proxies TherapyBoss screenshot scan to OpenAI gpt-4o vision; key never leaves Supabase | `OPENAI_API_KEY` |
| `tasks-auto-archive` | Daily cron — flips `is_archived = true` on kanban tasks completed 7+ days ago | (uses default `SUPABASE_SERVICE_ROLE_KEY`) |
| `auto-transition-pauses` | Daily cron — finds clinicians with `status='Paused' AND pause_end_date < CURRENT_DATE` and flips them back to Active in both `clinician_profiles` and `clinician_v2`, writing an audit row to `clinician_profile_status_log` with reason "Auto-transition: pause end date passed". Schedule: 11:00 UTC = 6 AM Chicago. Powers the pause lifecycle feature (Home alerts board). | `SUPABASE_SERVICE_ROLE_KEY` (default) |

All functions have CORS headers and use JWT verification (signed-in users only). Deploy via Supabase Dashboard → Edge Functions or CLI (`supabase functions deploy <name> --project-ref jpemlcuxjvynlbeygukb`).

**Note on `tb-scan-image` API key**: The OpenAI key for the AI scanner ("Scan with AI" in TB Import modal) lives in Supabase Edge Function secrets (`OPENAI_API_KEY`). If staff see "Missing scopes: model.request" — that's OpenAI's restricted-key error, not Anthropic. Fix: create a new OpenAI key with **All / Default permissions** (NOT "Restricted") and update the secret.

### Supabase Storage Buckets
| Bucket | Purpose | Access |
|---|---|---|
| `clinician-photos` | Clinician headshots (existing) | Per-clinician RLS — needs follow-up review |
| `staff-photos` | Portal user headshots used by chat + kanban + future avatars | Public-read, admin-write (`03_staff_directory.sql`) |

### Supabase SQL migrations (in `supabase/policies/`)
Run from Supabase Dashboard → SQL Editor in numerical order. All idempotent — safe to re-run.

| File | Purpose |
|---|---|
| `01_phase1_enable_rls.sql` / `01_phase1_rollback.sql` | Phase 1 RLS — locks 23 core tables to `authenticated` only. **APPLIED May 2026.** |
| `02_kanban_tables.sql` | Kanban schema: `boards`, `board_columns`, `tasks` + RLS + seed data for 3 default boards |
| `03_staff_directory.sql` | Adds `display_name`, `display_color`, `photo_url` cols to `staff_config`; creates `list_staff()` and `upsert_staff_profile()` SECURITY DEFINER RPCs; creates `staff-photos` storage bucket |
| `04_chat_messages.sql` | Team chat schema + RLS + adds the table to `supabase_realtime` publication so realtime broadcasts work |
| `05_auto_user_role.sql` | Backfills `user_roles` for orphan auth users + adds `on_auth_user_created` trigger that auto-inserts a `readonly` user_roles row on every `auth.users` INSERT. SECURITY DEFINER. Idempotent. **Run this any time after a fresh DB or to catch up older orphan accounts.** |
| `06_auto_staff_config.sql` | Backfills `staff_config` for orphan auth users + adds `on_auth_user_created_staff` trigger that auto-inserts an inactive `staff_config` row (`is_active=false`, `hourly_rate=0`, `pay_type='philippines'`, `timezone='Asia/Manila'`, `display_name = SPLIT_PART(email, '@', 1)`) on every signup. Lets new signups appear in the time-tracker admin dashboard "Needs setup" section without an admin having to copy UUIDs. SECURITY DEFINER. Idempotent. |
| `07_roster_review_fields.sql` | Adds three columns to `clinician_profiles`: `pause_reason TEXT`, `last_reviewed_at TIMESTAMPTZ`, `last_reviewed_by UUID`. Plus an index on `last_reviewed_at` for the "Need Review since X" filter in `roster-review.html`. All nullable + additive. Idempotent. |
| `08_vdr_billing.sql` | Creates the VDR (Visit Discrepancy Report) billing tables: `vdr_runs` (one row per processed `Create bills` export), `vdr_clinician_metrics` (per-run per-clinician aggregates for grading), `vdr_payer_metrics` (per-run per-payer revenue). Plus the `vdr-reports` storage bucket for generated XLSX files. RLS admin-only across the board. Idempotent. Drives the Billing sub-view in `finance.html`. |
| `09_clinician_vdr_summary.sql` | Adds `list_clinician_vdr_summary()` SECURITY DEFINER RPC that aggregates `vdr_clinician_metrics` per clinician — returns `run_count`, `total_visits`, `avg_visits_per_run`, `avg_sync_days` (visit-weighted), `avg_visit_minutes` (visit-weighted, NULL-aware), `total_charges`, `latest_run_at`. Surfaces in Roster Review (three default-on columns) + clinician profile in the map (three chips in the header quick-facts row). Aggregates are SECURITY DEFINER so editors see the numbers even though per-run rows remain admin-only. Idempotent. Self-healing: also re-adds `vdr_clinician_metrics.avg_visit_minutes` in case 08 hasn't been run. |
| `10_emergency_contact.sql` | Adds three columns to `clinician_profiles`: `emergency_contact_name TEXT`, `emergency_contact_phone TEXT`, `emergency_contact_relation TEXT`. Drives the Emergency Contact drawer in `roster-review.html`. TB doesn't track emergency contacts, so this is portal-managed. Idempotent. |
| `11_pause_lifecycle.sql` | Adds `list_pause_alerts()` SECURITY DEFINER RPC that returns active pause/vacation alerts (pause_ending_soon / pause_ending_today / pause_starting_soon / pause_starting_today / just_returned). Drives the Home page 📰 News & Alerts board. Pause-end alerts: 1 day before + day-of; pause-start alerts: **14 days before through day-of** (widened from the original 3-day window for coverage planning); just-returned: visible 5 days after auto-transition. Read-only, authenticated-accessible. Idempotent. |
| `12_evaluation_compliance.sql` | Creates `evaluation_compliance_items` (one row per (patient_id, referral_id) anchored to TB's Active Services report) + 4 RPCs: `list_evaluation_compliance()` (SECURITY DEFINER read), `upsert_evaluation_items(rows JSONB, batch_id UUID)` (bulk import — dedupes inbound payload via DISTINCT ON, preserves user-edited columns on conflict), `update_evaluation_item(id, ...)` (targeted single-row patch), `clear_evaluation_compliance()` (admin-only nuke; returns row count deleted). RLS: SELECT for all authenticated, write for admin+editor, clear for admin only. Drives the Evaluation tile in `compliance.html`. Idempotent. |
| `13_eval_referral_date.sql` | Adds `referral_date DATE` column to `evaluation_compliance_items`, flips category default from `'Active'` → `'Assigned'`, migrates any existing `'Active'` rows → `'Assigned'`, and rebuilds `upsert_evaluation_items` to accept + persist `referral_date`. Drives the date-bucketed "Intake — Assigned by date" region in the Evaluation tile UI. Idempotent. |
| `14_eval_patient_list_join.sql` | Adds 5 columns to `evaluation_compliance_items` populated by the second TB report (Patient List XLSX): `episode_instructions TEXT`, `service_protocol TEXT`, `hold_since DATE`, `hold_reason TEXT`, `hold_details TEXT`. Rebuilds `upsert_evaluation_items` to accept all the new fields AND auto-promote rows with `hold_since IS NOT NULL` to `category='Hold/Hospital'` on INSERT (UPDATE preserves user-edited category). Drives the two-file import flow + the multi-line Status Notes cell (collapsible TB-managed reference lines) in `compliance.html`. Idempotent. |
| `15_eval_schedule_enrichment.sql` | Adds 9 columns to `evaluation_compliance_items` for the phase-2 Scheduled Appointments import: `next_eval_date DATE`, `next_eval_activity TEXT`, `next_eval_clinician TEXT`, `next_eval_confirmed BOOLEAN`, `next_eval_appt_id TEXT`, `next_eval_note TEXT`, `last_eval_attempted DATE`, `scheduled_appt_count INTEGER`, `schedule_imported_at TIMESTAMPTZ`. New RPC `update_eval_schedule_info(rows jsonb)` matches on (patient_id, service) and UPDATES only (no inserts — rows must exist from the base import first). Drives the "Eval Sched" column and SLA indicators (24hr-schedule / 48hr-visit / 48hr-sync rules) in the Evaluation tile UI. Idempotent. |
| `16_eval_visits_enrichment.sql` | Adds 10 columns to `evaluation_compliance_items` for the phase-3 Patient Visits import: `eval_visit_date DATE`, `eval_visit_type TEXT`, `eval_visit_clinician TEXT`, `eval_note_completed_at TIMESTAMPTZ`, `eval_completion_hours NUMERIC` (sync-delay tracker), `eval_visit_id TEXT`, `reeval_visit_date DATE`, `reeval_note_completed_at TIMESTAMPTZ`, `last_visit_actual_date DATE`, `visits_imported_at TIMESTAMPTZ`. New RPC `apply_eval_visits(rows jsonb)` UPDATES only (matches on (patient_id, service)) AND auto-derives `sync_status`: eval visit found + note completed → `'synced'`; eval visit found + note pending → `'eval_done_not_synced'`; no eval visit → sync_status untouched. Drives the merged "Eval Sched / Eval Done" cell + the 48-hr sync SLA chip. Idempotent. |
| `17_clinician_visit_period_metrics.sql` | Creates `clinician_visit_period_metrics` table (one row per clinician × bi-weekly pay period, Thursday-anchored at 2024-10-17) populated by either (a) the Eval Compliance Patient Visits import (current-quarter refresh) or (b) the Roster Review admin-only **📥 Bulk Import Visits** button (historical backfill, supports multi-year files up to ~270K visit rows). New RPCs `upsert_clinician_visit_periods(rows jsonb)` (write, with name-normalized clinician_id auto-resolution) and `list_clinician_visit_summary()` (read, same field shape as `list_clinician_vdr_summary` so Roster can swap sources transparently). Roster Review now prefers Visits-derived metrics (every visit incl. non-billable) and falls back to VDR-derived (Create-bills) when Visits hasn't been imported for that clinician. Idempotent. |
| `18_clinician_dob.sql` | Adds `dob DATE` column to `clinician_profiles` + `idx_clinician_profiles_dob_md` (month*100+day index for fast birthday-window queries). Two RPCs: (1) `list_birthday_alerts()` returns Active+Paused clinicians whose birthday is today (`birthday_today`) or tomorrow (`birthday_tomorrow`) — drives 🎂 alerts on the Home page News & Alerts board. (2) `list_birthdays_in_month(year, month)` returns every Active+Paused clinician with a birthday in that calendar month, sorted by day with `days_offset` (negative for past, 0 today, positive upcoming) — drives the Home page **🎂 Birthdays this month** drawer (prev/next month nav, grouped Today / Upcoming / Earlier-this-month, click-to-open clinician profile). DOB also surfaces in: Roster Review (default-hidden `DOB (MM/DD)` column with celebratory tint when birthday is in next 7 days), Map profile header (🎂 chip in quick-facts row). DOB is fed via the existing Map → Bulk Import flow's clinician_master mode (column aliases: DOB / Date of Birth / Birthday / Birth Date). `normalizeImportDateValue` extended to detect Excel serial dates ([1, 80000] range) since TB exports DOB without a date number format. Additions Only mode opportunistically backfills DOB for matched-existing clinicians whose DB `dob` is NULL (narrow exception so users don't need to switch to Full Initial Load). Idempotent. |
| `19_clinician_payroll_runs.sql` | Creates `clinician_payroll_runs` table (admin-only RLS) — one row per pay-period audit of the TB "Prepare payroll" Excel. Stores period bounds (Sun-Sat) + pay date (Mon = period_end + 16d), top-line totals (pay/expenses/visits/payable/non-payable/distinct clinicians), audit state machine (`open → audited → exported → paid` with timestamps + actor IDs), and JSONB snapshots (`per_clinician_payload` for the audit table, `all_visits_payload` for drill-down). Six admin-only RPCs: `upsert_clinician_payroll_run(...)` (re-import preserves audit state on conflict), `list_clinician_payroll_runs()` (summary for history table), `get_clinician_payroll_run(id)` (full detail), `mark_clinician_payroll_audited(id, notes)`, `mark_clinician_payroll_exported(id)`, `mark_clinician_payroll_paid(id)`. Drives the Finance → Payroll → 💵 Clinician Payroll Audit card (import modal, history table, per-clinician drill-down). Phase 3 (QB export) will read from these stored snapshots. Idempotent. |
| `20_clinician_payment_method.sql` | Adds `payment_method TEXT NOT NULL DEFAULT 'check'` column to `clinician_profiles` with CHECK constraint enforcing 4 values: `'check'` (default — accounting creates QB bill, user generates check), `'direct_deposit'` (bank ACH), `'zelle'` (P2P transfer), `'w2'` (QB Payroll). Index on the column for export-grouping queries. Drives the Roster Review "Pay Method" column (default hidden, opt-in via Columns ▾) — inline 4-option dropdown writes here. Phase 3 (export to accounting) reads this column to split the audited payroll payload into per-method export files (QB bill IIF / ACH file / Zelle manual list / QB Payroll import). Idempotent. |

### Mapbox
- **Access token:** `pk.eyJ1IjoiZGl6dG9ueTY3IiwiYSI6ImNtbjVjNW1seTA4dWsycXBpbjRreHVoOHQifQ.7wgw3ocLrvjEmpKdx-vP1A`
- **Used in:** clinician-map.html (v3.0.1), referrals.html (v3.3.0)

---

## Shared Supabase Tables

| Table | Used By | Notes |
|---|---|---|
| `clinician_v2` | clinician-map | |
| `clinician_profiles` | clinician-map, referrals (audit) | |
| `clinician_zip_coverages` | clinician-map | |
| `home_health_agencies` | clinician-map, referrals | |
| `referrals` | clinician-map (overlay), referrals, kanban (linked entity) | |
| `referral_contacts` | clinician-map (overlay), referrals | |
| `staff_config` | time-tracker, kanban, chat | Now has `display_name`, `display_color`, `photo_url` columns used portal-wide for the staff directory |
| `time_entries` | time-tracker | |
| `time_edit_requests` | time-tracker | |
| `user_roles` | all files | Drives admin gates (board management, staff profiles, etc.) |
| `language_options` | clinician-map | |
| `therapy_boss_*` | clinician-map (bulk import) | |
| `boards` | kanban | Top-level workflows; admin-edit only |
| `board_columns` | kanban | Per-board columns; admin-edit only |
| `tasks` | kanban | Tasks; all auth users can CRUD; can link to clinician/referral/compliance_item/agency |
| `chat_messages` | chat-widget.js (all pages) | Single team channel; SELECT for all auth users; INSERT only as self |
| `evaluation_compliance_items` | compliance.html (Evaluation tile) | One row per (patient_id, referral_id) anchored to TB Active Services; portal-managed `category`/`sync_status`/`status_notes`/`clinician_id`; admin+editor write |
| `clinician_visit_period_metrics` | roster-review.html | One row per (clinician_name, pay_period_start) — pre-aggregated visit counts + avg sync days + avg duration. Populated by the Eval Compliance Patient Visits import (same file, two consumers). Read by Roster via `list_clinician_visit_summary()` which mirrors the VDR summary shape so the cell renderer is source-agnostic. |

### Database functions (RPCs)
| RPC | Purpose | Caller |
|---|---|---|
| `list_staff()` | Returns user_id, email, display_name, display_color, photo_url, role for all users. SECURITY DEFINER bypasses auth.users RLS. | kanban, chat-widget |
| `upsert_staff_profile(user_id, name, color, photo_url)` | Admin-only — sets display fields. NULL leaves a field unchanged. | kanban Manage Staff modal |
| `clear_staff_field(user_id, field)` | Admin-only — explicitly NULLs `display_name` / `display_color` / `photo_url` | kanban Manage Staff modal |

---

## User Roles

Three roles stored in `user_roles` (user_id, role):
- **admin** — full access including user management, bulk import, settings
- **editor** — can edit clinicians and referrals, cannot manage users
- **readonly** — view only (default for new signups)

**Default-on-signup**: Since `05_auto_user_role.sql` and `06_auto_staff_config.sql`, every new account gets a `user_roles` row (`readonly`) AND a `staff_config` row (`is_active=false`) created automatically. Admins promote via:
- **Map → 👥 Users** modal (admin only) — reads via `list_staff()` RPC so even brand-new orphans appear immediately; the role dropdown does an upsert so promoting an un-roled user works
- **Time Tracker → Dashboard** — un-set-up staff appear under a yellow "⚠ N new users need setup" banner with a **Set up** button that jumps to the Settings tab and highlights the row
- **Time Tracker → Settings** — every staff name is now an editable input that calls `upsert_staff_profile` RPC; admin can rename + set rate + flip Active in one save

---

## How to Start a Session

1. Read this file (`CLAUDE.md`) for project overview
2. Read the specific CLAUDE file for the area you're working on (e.g., `CLAUDE-map.md`)
3. Read only the relevant section of the HTML file using line offsets if needed

**Always update the relevant CLAUDE file at the end of the session** with any new functions, schema changes, or completed features. Ask: "Update the CLAUDE file with what we built today."

---

## Pending Work (as of May 27, 2026)

### Done since last update
- ✅ **Time Tracker — Wise payment memo** (`time-tracker.html` → Pay Period) — each 🇵🇭 Wise row has a 📋 copy button next to "Send via Wise" that copies a special-char-free description for Wise's memo field, e.g. `Payroll 0427 to 0508 40 X 466` (period MMDD→MMDD · hours · X · rate). `buildWiseMemo()` formats dates as MMDD in ADMIN_TZ, drops the rate's decimal (`4.66`→`466`), and replaces a fractional-hours dot with a space (`40.5`→`40 5`); a `[^A-Za-z0-9 ]` strip guards against any Wise-illegal char. Click-to-copy uses `navigator.clipboard` with a hidden-textarea `execCommand` fallback; delegated on the tbody. 🇺🇸 "Direct payment" rows have no button.
- ✅ **Time Tracker — inline manual hours entry** (`time-tracker.html` → Pay Period) — removed the "✏ Enter Hours" popup + `#bulk-hours-modal`; the HOURS cell in the pay table is now a direct inline `<input>` per active staff row (commit on blur/Enter via `saveManualHoursForStaff()`, writing the same synthetic `is_manual` time_entry; 0 clears the manual entry, real clock-in/out shifts untouched). Added a sort/filter toolbar above the table: debounced **search by name**, **sort A–Z**, and **pay-type chips** (All / 🇵🇭 Wise / 🇺🇸 USD). Grand totals always compute over all active staff (search/filter-independent); the opposing total row hides when a pay-type filter is active. Pay Period tab is already admin-gated (`#admin-view`).
- ✅ **Clinician Payroll Audit + payment-method tagging** (`finance.html` → Payroll → 💵 Clinician Payroll Audit) — TB "Prepare payroll" Excel import with SUBMITTED-date period detection (we pay by sync date, not visit date) and a "most visits wins" target picker + yellow multi-period sanity warning. Per-clinician audit table with sticky thead, title-cased names, search-to-isolate, exclude/restore visits, free-form adjustments (date/desc/amount), per-visit pay editing in place with redline markup (strikethrough original + bold new + ↶ revert), auditor flags ($0 / missing $ / late-sync / short visit / revisions). Audit state machine open → audited → exported → paid with timestamps + actor IDs (Reopen returns to open); all edit affordances gate off status. Calendar drives the workflow — click a period → opens audit (View if a run exists, Import if not); "AUDIT NOW" pill on the period whose pay date is the next upcoming Monday. History row delete button (two-step confirm). Migration 19 (table + 7 admin-only RPCs) + Migration 20 (`payment_method` column with 4-value CHECK constraint, default 'check', plus Roster Review opt-in "Pay Method" column with inline dropdown for tagging clinicians as check / direct_deposit / zelle / w2 to drive Phase 3 export grouping).
- ✅ **Portal nav 🏠 Home link** on every tool's standalone header — first link in the nav, points to `index.html` (shell's Home dashboard pane). Hidden by `.in-iframe-shell` CSS when running inside the shell.
- ✅ **Map: Isolate Clinician button state fix** — `toggleClinicianIsolation()` now syncs both profile header isolate buttons after toggle (was only calling `applyFilters()`, leaving the button stuck on its inactive label/style despite the underlying filter actually working).
- ✅ **Roster Review built + polished** (`roster-review.html`) — sticky thead + sticky Name column for big-table scrolling, inline pause editor with Personal/Sick/Vacation/Other dropdown, EMR chips click-to-toggle (writes to `clinician_profiles.emr_capabilities` JSONB — same surface as the map), Phone/Email locked with 🔒 indicator (TB source-of-truth), Emergency Contact drawer (managed in portal since TB doesn't track it), discipline + status pill stacked under each name. Restrictions drawer uses roster-only typeahead — no free-text. Performance metrics (Avg Sync Days / Avg Visits/Run / Avg Visit Time) prioritized right after Status with green/amber/red tint on sync days. Surgical EMR toggle keeps scroll locked; renderTable() preserves scroll + focus across re-renders to prevent view-jump on edits.
- ✅ **Finance area** (`finance.html`, admin-only) — landing page with Payroll + Billing tiles. Payroll surfaces current pay period totals + link to Time Tracker. Billing now contains four cards: VDR Runner / Inline Preview / History & Trends / Invoice Converter (IIF).
- ✅ **Billing → VDR Runner** — browser-side port of the user's local `Processed_VDR.py`. SheetJS for input, ExcelJS for output, Chart.js for inline charts. Persists every saved run + per-clinician + per-payer aggregates. 📊 View button on history rows rebuilds the inline preview from a stored `prepared_rows` JSONB snapshot. Replaces the legacy Processed_VDR aggregator script (filename-scanner) with a single SQL query + trend chart.
- ✅ **VDR per-clinician metrics surfaced on Roster + Map profile** — `09_clinician_vdr_summary.sql` RPC rolls up `vdr_clinician_metrics` per clinician (visit-weighted avgs). Default-on columns in Roster Review; three chips (Sync / Visits/Run / Avg Visit Time) in the map's profile-header quick-facts row.
- ✅ **Patient Visits-derived metrics (Roster + Map)** — `17_clinician_visit_period_metrics.sql` adds a per-(clinician, pay_period) aggregation populated by the Eval Compliance Patient Visits import OR a separate admin-only **📥 Bulk Import Visits** button on Roster Review (one-shot multi-year backfill, handles ~270K rows). `list_clinician_visit_summary()` mirrors the VDR-summary shape so Roster + Map use the same cell renderers — Visits is preferred, VDR is fallback. Both pages strip trailing discipline codes (PT/PTA/OT/OTA/ST/STA/SLP/OTR/RN/LPN/CNA/MD/DO/DPT/NP/PA) on name-based lookup to match TB's "Basma Rafael PT" format against `clinician_v2.name`'s "Basma Rafael".
- ✅ **Billing → Invoice Converter (IIF)** — browser-side port of the user's local IIF cleanup Python. Drag-drop a raw .iif, strip 11 cruft columns, drop TAXABLE/negative rows, rename headers, Medicare → Medicare Part B. substitution, download cleaned `Dependable_Invoice_<YYYY-MM-DD>.iif` for upload to SaaSant → QB.
- ✅ **Shared cursor on map** — toolbar toggle + Shift-hold hotkey broadcast your cursor (lng/lat) via Supabase Realtime broadcast channel `map-cursors-v1`. Other map viewers see colored cursor + name label. Works across different zoom levels. 25Hz throttled, no DB writes.
- ✅ **Portal shell** — `index.html` is now a real iframe shell hosting 7 tools (Map / Referrals / Time / Compliance / Kanban / Roster / Finance) + a Home dashboard pane. State preserves across tabs. Finance tab is admin-only-revealed.
- ✅ **Self-service signup + forgot/reset password** — full 4-mode auth flow in the shell login screen.
- ✅ **Auto-creation triggers** — `05_auto_user_role.sql` and `06_auto_staff_config.sql` mean every signup gets a readonly role + inactive staff_config row.
- ✅ **Time Tracker — "Needs setup" section + editable display names + auto-refresh on Settings tab**. Pay Period view now has a diagnostic strip showing UTC bounds + query/in-period row counts to debug period-filter issues.
- ✅ **Chat presence debounce + iframe guard** — refresh/tab-switch no longer fires join/leave spam; widget only renders at shell level.
- ✅ **Manage Users modal in clinician-map** — switched to `list_staff()` RPC + upsert for role changes.

### Still pending
- **Phase 1 RLS** — 23 tables locked. Three tables still UNRESTRICTED (`clinician_referrals`, `clinician_territory_versions`, `pay_period_adjustments`) — easy follow-up SQL.
- **Phase 2 RLS** — per-role policies (admin/editor/readonly) tied to `user_roles`.
- **Storage bucket RLS** — `clinician-photos` bucket needs its own policy review.
- **`tasks-auto-archive` Edge Function** — written, not yet deployed.
- **Time Tracker Pay Period bug** — user reported "whatever period I select displays the same data" with hours that belong to a prior period showing in newer period view. Diagnostic strip shipped to investigate; needs reproduction data to root-cause.
- **Shell-aware clinician open from Roster** — clicking a clinician name in Roster currently spawns a new browser tab. Plan captured in `restrictions-as-in-agencies-shiny-kahan.md` "Future work" — switch to `parent.shellSwitchTab('map', 'clinician=…')` when in shell.
- **VDR — Phase 2 direct QB connect** — Plan in `its-used-to-import-merry-rabbit.md`. Bypasses SaaSant via QuickBooks Online API + Supabase Edge Function. ~1-2 weeks of work. Decision: pending SaaSant pain experience.
- **Roster — manual unmatched clinician linker** — VDR's auto-name-match leaves `clinician_id = null` if a TB export name doesn't match `clinician_v2.name` exactly. Need a small admin UI to manually link names. Currently aggregates still flow via the name-normalized fallback so this isn't urgent.
- **time-tracker.html** — Task #4: time edit approval system + 10hr hard stop (partially built, needs testing/polish).
- **compliance.html** — not yet explored or documented.
- **Kanban v2 ideas** — auto-tasks, comments, file attachments, @mentions, recurring tasks.
- **Chat v2 ideas** — multiple channels, DMs, file/image uploads, @mentions, read receipts, edit/delete UI.
