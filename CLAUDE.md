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
| `compliance.html` | Compliance dashboard — not yet fully documented | (read the file directly) |
| `kanban.html` | Portal-wide kanban task board — multiple boards, SLAs, drag/drop, admin board management, staff profiles | `CLAUDE-kanban.md` |
| `roster-review.html` | **Bulk clinician editor for HR / coordinator review sessions** — table of every clinician with inline edits for status (Active/Paused/Inactive), pause dates + reason, DNR flag, notes, and a click-to-open side drawer for restrictions. ✓ Reviewed checkbox stamps `last_reviewed_at`/`last_reviewed_by` for audit trail of who reviewed whom and when. Filters: status / discipline / "Need Review" / "Returning soon" / "Paused 30d+". Multi-select bulk actions + CSV export. Admin + Editor write access. | (this file + comments in roster-review.html) |
| `finance.html` | **Admin-only Finance area** with sub-views: Payroll (summary linking to Time Tracker's pay period flow) and **Billing → VDR runner**. The Billing view ingests a `Create bills.xlsx` from TherapyBoss in the browser (SheetJS), flags discrepancies (OutOfRange / ShortAndBillable / MissedVisit / EvalTimeAlert) just like the legacy `Processed_VDR.py`, shows inline stats + Chart.js charts + tabbed discrepancy tables, generates a downloadable multi-sheet XLSX (ExcelJS), and persists every saved run to `vdr_runs` + `vdr_clinician_metrics` + `vdr_payer_metrics` with the report XLSX in the `vdr-reports` storage bucket. History table shows past runs with payroll-date markers (bi-weekly Wed before 2024-10-17, Thu after) — replaces the legacy aggregator script. Two-layer admin gate (shell tab + page-level). | (this file + comments in finance.html) |
| `chat-widget.js` | Shared team-chat widget — included on every portal page; old-school single-channel team chat with presence + sound + tab-flash | `CLAUDE-kanban.md` (chat section) |
| `index.html` | **Portal shell** — owns the login/signup/forgot-password screen, header tabs, and 5 lazy-loaded iframes (one per tool). Home pane is a stats dashboard. State preserves across tabs. | (this file + comments in index.html) |

**Iframe shell (May 2026):** `index.html` is now an iframe shell instead of a simple redirect. The header hosts 6 tabs (🏠 Home · 🗺️ Map · 📋 Referrals · ⏱️ Time · ✅ Compliance · 🗂️ Kanban). Each tool tab is an `<iframe>` whose `src` is set lazily on first click. Subsequent clicks just toggle `hidden`, so the iframe's state (map zoom, kanban board, scroll, filters) is preserved. URL is `?tab=<id>` and updates via `history.pushState`; back/forward works natively. Exposes `window.shellSwitchTab(tabId, queryString)` so tools (in iframes) can call up to the shell to cross-navigate without losing sibling state.

**Per-tool iframe-detection:** Each tool HTML has a tiny script in `<head>` that adds `html.in-iframe-shell` when `window.self !== window.top`. CSS rules then hide each tool's duplicate chrome (portal nav strip, brand, user chip, sign-out) when running inside the shell. Tools accessed via direct URL still show their full header — backward compatible.

**Portal nav strip** (Map / Referrals / Time / Compliance / Kanban) is the fallback navigation when a tool is loaded standalone. Uses real `<a href>` links so Ctrl/Cmd+click → new tab works for free. All pages use `localStorage` auth → SSO across the portal, no re-login when switching tabs.

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

## Pending Work (as of May 12, 2026)

### Done since last update
- ✅ **Portal shell** — `index.html` is now a real iframe shell hosting all 5 tools + a Home dashboard pane. State preserves across tabs.
- ✅ **Self-service signup + forgot/reset password** — full 4-mode auth flow in the shell login screen.
- ✅ **Auto-creation triggers** — `05_auto_user_role.sql` and `06_auto_staff_config.sql` mean every signup gets a readonly role + inactive staff_config row. No more "orphan in auth.users" problem.
- ✅ **Time Tracker — "Needs setup" section** — un-set-up staff appear on the admin Dashboard with a Set up button. Removed stale "Database Setup" block from Settings.
- ✅ **Time Tracker — editable display names + auto-refresh on Settings tab** — admin renames staff inline; uses the same `upsert_staff_profile` RPC as Kanban Manage Staff, so changes propagate site-wide.
- ✅ **Chat presence debounce** — refresh / iframe-tab-switch no longer fires the "X joined / X left" spam to other users (25s leave debounce + 60s join cooldown + consecutive-dupe coalescing in `chat-widget.js`).
- ✅ **chat-widget.js iframe guard** — `if (window.self !== window.top) return;` prevents duplicate chat widgets inside iframes; only the shell-level widget renders.
- ✅ **Manage Users modal in clinician-map** — switched from direct `user_roles` SELECT to the `list_staff()` RPC so orphan users are visible; role changes now use `upsert` so non-roled users can be promoted.

### Still pending
- **Phase 1 RLS** — 23 tables locked. Three tables still UNRESTRICTED (`clinician_referrals`, `clinician_territory_versions`, `pay_period_adjustments`) — easy follow-up SQL.
- **Phase 2 RLS** — per-role policies (admin/editor/readonly) tied to `user_roles`.
- **Storage bucket RLS** — `clinician-photos` bucket needs its own policy review (`staff-photos` is already locked down per `03_staff_directory.sql`).
- **`tasks-auto-archive` Edge Function** — written, not yet deployed. Optional; Done-column bloat over time is the only consequence of skipping. Deploy via `supabase functions deploy tasks-auto-archive --project-ref jpemlcuxjvynlbeygukb` then schedule cron `0 3 * * *`.
- **clinician-map.html** — performance optimizations discussed (GeoJSON layers, virtual scroll, staggered data load) — partially landed.
- **time-tracker.html** — Task #4: time edit approval system + 10hr hard stop (partially built, needs testing/polish).
- **compliance.html** — not yet explored or documented.
- **Kanban v2 ideas** — auto-tasks (new referral → "staff this" task; nearing compliance renewal → auto-task; inactive 60+ days → reach-out task), task comments, file attachments, @mentions, recurring tasks. See `CLAUDE-kanban.md` "Out of scope" section.
- **Chat v2 ideas** — multiple channels, DMs, file/image uploads, @mentions, read receipts, edit/delete UI (DB supports edit/delete via RLS already).
- **Cross-tool realtime name sync** — names auto-refresh on Settings tab entry today; could be pushed via Supabase Realtime if cross-tool drift becomes a problem.
