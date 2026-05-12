# DependableCare Time Tracker — Project Reference

This document gives Claude full context to continue development on `time-tracker.html` without re-reading the full file from scratch. Read this first, then read the relevant section of the HTML file for the specific area you're working on.

---

## Project Overview

`time-tracker.html` is a standalone time tracking and payroll tool for **DependableCare**. Single HTML file, no framework, no build step — plain HTML/CSS/JS with Supabase. Lives in the **Map Project** folder alongside `clinician-map.html` and `referrals.html`.

---

## File

### `time-tracker.html`

**What it does:**
- Clock in/clock out for individual staff members
- Live HUD (heads-up display) showing currently clocked-in staff with elapsed time and photos
- Pay period view — time entries grouped by pay period with totals
- Dashboard — admin overview of all staff hours, pay period summaries
- Settings — staff configuration (name, role, hourly rate, pay type, photo)
- Approval queue — managers review and approve/reject time edit requests
- Hard stop enforcement — prevents shifts exceeding 10 hours (warns at threshold, forces clock-out)
- Manual time entry — admin can create entries directly
- Adjustment tool — admin can modify existing entries

---

## Supabase Tables

| Table | Purpose |
|---|---|
| `staff_config` | Staff records — `user_id, display_name, hourly_rate, pay_type, timezone, is_active, photo_url, display_color, wise_recipient_id, wise_name, wise_email`. Auto-populated on signup by `06_auto_staff_config.sql` trigger (defaults: `is_active=false`, `hourly_rate=0`, `pay_type='philippines'`, `timezone='Asia/Manila'`, `display_name = SPLIT_PART(email, '@', 1)`). |
| `time_entries` | Clock in/out records (`user_id, clock_in, clock_out` — `clock_out IS NULL` means actively clocked in. Also `notes, is_manual, approved, duration_minutes`). |
| `time_edit_requests` | Edit requests from staff (entry_id, staff_id, requested_clock_in, requested_clock_out, reason, status: pending/approved/rejected) |
| `user_roles` | Role assignments (user_id, role: admin/editor/readonly). Auto-populated on signup by `05_auto_user_role.sql` trigger (default: `readonly`). |

## SQL migrations relevant to Time Tracker

- **`03_staff_directory.sql`** — adds `display_name`, `display_color`, `photo_url` columns; creates `upsert_staff_profile()` (admin-only RPC used for renames).
- **`05_auto_user_role.sql`** — every new auth signup gets a `user_roles(role='readonly')` row.
- **`06_auto_staff_config.sql`** — every new auth signup gets a `staff_config` row with safe inactive defaults. Time tracker's admin dashboard surfaces these in a "Needs setup" section.

---

## Key Functions

| Function | Purpose |
|---|---|
| `handleSession(session)` | Runs after auth; determines role and loads appropriate view |
| `loadStaffConfig()` | Fetches all staff from `staff_config` and updates the global `staffConfig` array. Called at login and on Settings tab entry (`switchTab`). |
| `loadStaffView()` | Renders the staff clock-in/out grid |
| `toggleClock(staffId)` | Clocks a staff member in or out; writes to `time_entries` |
| `startHardStopMonitor()` | Polls active clock-ins; warns at 9.5h, forces clock-out at 10h |
| `openEditRequest(entryId)` | Opens modal for staff to request a time edit |
| `submitEditRequest(entryId)` | Posts edit request to `time_edit_requests` |
| `approveRequest(requestId)` | Admin approves an edit request; updates `time_entries` + sets request status to "approved" |
| `rejectRequest(requestId)` | Admin rejects an edit request; sets status to "rejected" |
| `approveAll()` | Bulk-approves all pending edit requests |
| `renderApprovals()` | Renders the pending approvals tab |
| `renderDashboard()` | Renders admin dashboard. **Two sections**: active staff cards on the bottom + a "Needs setup" group on top (yellow banner + dashed-border cards) for any staff where `is_active = false`. Click **Set up** → switches to Settings tab and highlights the row. |
| `renderPayPeriod()` | Renders pay period view for the current user. Still filters `is_active = true` — inactive auto-created staff don't pollute payroll. |
| `renderSettings()` | Renders staff settings management tab. **Display name is now an editable `<input class="s-name-input">`** with `data-orig` snapshot for skip-if-unchanged saves. |
| `saveStaffConfig(uid, btn)` | Saves edits to a staff row. **Two writes**: (a) if the name changed, calls `db.rpc('upsert_staff_profile', { p_user_id, p_display_name })` — the SAME admin-gated RPC that Kanban Manage Staff uses; (b) operational fields (rate / tz / active / pay_type / wise_*) via direct table UPDATE as before. Skipped name RPC keeps unchanged-name saves at exactly one DB call. |
| `openStaffSetup(userId)` | Switches to the Settings tab and scrolls + briefly highlights the matching `.setting-row[data-uid="…"]` so admin can fill in rate / tz / activation for a newly-signed-up staff member. Called from the "Set up" button on a "Needs setup" dashboard card. |
| `renderHUD()` | Renders the live HUD bar showing clocked-in staff with photos and elapsed time |
| `uploadPhoto(staffId)` | Handles photo upload for a staff member |
| `openManualModal(staffId)` | Opens modal for admin to manually create a time entry |
| `saveManualEntry()` | Saves a manually created time entry |
| `openAdjModal(entryId)` | Opens adjustment modal for an existing entry |
| `saveAdjustment()` | Saves an adjusted time entry |
| `openAddStaffModal()` | Opens modal to add a new staff member (manual UUID entry). Rarely needed since `06_auto_staff_config.sql` auto-creates rows on signup, but kept as an escape hatch. |
| `saveNewStaff()` | Creates / upserts a new staff record in `staff_config` (direct table write, not the RPC — sets all fields at once including the operational ones the RPC doesn't touch). |
| `switchTab(name)` | Tab switcher. **When entering Settings**, awaits `loadStaffConfig()` then re-renders — picks up name changes from Kanban Manage Staff or direct Supabase edits without a page refresh. |
| `escAttr(s)` | One-line HTML-attribute escape helper; used in the editable name input. |

---

## Integrations & Credentials

### Supabase
- **URL:** `https://jpemlcuxjvynlbeygukb.supabase.co`
- **Anon key:** hardcoded in file (search `supabaseKey` or `SUPABASE_KEY`)
- **Auth:** Email/password; role determined from `user_roles` table after login

---

## User Roles

- **admin** — full access: dashboard, settings, approvals, manual entries, adjustments
- **editor** — can clock staff in/out, submit edit requests; no settings or dashboard
- **readonly** — view only

---

## Tabs / Views

| Tab | Roles | Purpose |
|---|---|---|
| Clock | All | Staff clock-in/out grid |
| HUD | All | Live view of currently clocked-in staff (with photos + elapsed time) |
| Pay Period | All | Current user's time entries by pay period |
| Dashboard | Admin | All staff hours summary |
| Approvals | Admin | Pending time edit request queue |
| Settings | Admin | Staff config management |

---

## Pending Features (as of last session)

### Task #4 — Time Edit Approval System + 10hr Hard Stop
**Status:** In progress (partially built, not complete)

**What was built:**
- `time_edit_requests` table exists in Supabase
- `openEditRequest` / `submitEditRequest` — staff can submit requests
- `approveRequest` / `rejectRequest` / `approveAll` — admin approval queue
- `renderApprovals()` — approval tab renders pending requests
- `startHardStopMonitor()` — polling hard stop at 10h with warning at 9.5h

**What may still be needed:**
- Verify hard stop actually writes clock_out to `time_entries` when limit is hit
- Confirm approval workflow correctly updates `time_entries.clock_in`/`clock_out` after approval
- Test that rejected requests notify the staff member
- UI polish on approval queue (timestamps, formatting)

---

## HUD (Task #3 — Completed)
- Shows all currently clocked-in staff as cards with: name, role, photo, elapsed time (live-updating)
- Photos sourced from `staff_config.photo_url`
- `renderHUD()` rebuilds every 60s (or on clock toggle)
- If no staff clocked in, shows a friendly empty state

---

## Common Gotchas

- **`startHardStopMonitor()`** — runs on a `setInterval`; make sure it's only started once (don't double-start on re-renders)
- **Pay period logic** — pay periods are bi-weekly; verify start date anchor is correct for DependableCare's schedule
- **Photo upload** — goes to Supabase Storage; `photo_url` is saved back to `staff_config`
- **Manual entries** — `is_manual: true` flag on `time_entries`; display differently in pay period view
- **PIN auth** — staff may use a PIN (stored in `staff_config.pin`) rather than email login for clock-in
- **Display name is now editable in Settings** — admins can rename inline; the rename goes through the same `upsert_staff_profile` RPC as Kanban → Manage Staff (single source of truth, admin-gated). Editing only the rate (not the name) still triggers exactly ONE DB call because the name RPC is skipped when unchanged.
- **Settings tab refreshes `staffConfig` on entry** — if you renamed someone in Kanban and switch to Time → Settings, you'll see the new name without a page refresh. Dashboard tab still uses the cached array, so if you need a fully fresh dashboard, click Settings then back to Dashboard.
- **Auto-created staff are `is_active = false`** — payroll math + pay period view continue to filter active-only, so an un-set-up signup never appears in totals. They only show up in the Dashboard tab's "Needs setup" banner until admin flips Active to true.
- **The "+ Add Staff Member" modal is still there** — for edge cases where admin needs to seed a row with a known UUID. Day-to-day, signups handle it.
- **The old "Database Setup" SQL block was removed from the Settings tab** (it was just a placeholder pointing to a non-existent `time-tracker-setup.sql` file).

---

## Navigation

This file links to:
- `index.html` — portal home

---

## Development Tips

- **Read `CLAUDE.md` (clinician-map) first** for shared credentials (Supabase URL/key) and project context
- **Hard stop monitor** — use `clearInterval` on the existing handle before restarting to avoid duplicates
- **Supabase AbortError** — same "steal" lock issue as other files; add retry logic to any fetches done on page load
- **Update this file** at the end of each session with new functions, table changes, or completed tasks
