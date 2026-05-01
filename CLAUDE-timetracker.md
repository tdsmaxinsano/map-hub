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
| `staff_config` | Staff records (name, role, pay_type, hourly_rate, photo_url, active, pin) |
| `time_entries` | Clock in/out records (staff_id, clock_in, clock_out, duration_minutes, notes, is_manual, approved) |
| `time_edit_requests` | Edit requests from staff (entry_id, staff_id, requested_clock_in, requested_clock_out, reason, status: pending/approved/rejected) |
| `user_roles` | Role assignments (user_id, role: admin/editor/readonly) |

---

## Key Functions

| Function | Purpose |
|---|---|
| `handleSession(session)` | Runs after auth; determines role and loads appropriate view |
| `loadStaffConfig()` | Fetches all staff from `staff_config` |
| `loadStaffView()` | Renders the staff clock-in/out grid |
| `toggleClock(staffId)` | Clocks a staff member in or out; writes to `time_entries` |
| `startHardStopMonitor()` | Polls active clock-ins; warns at 9.5h, forces clock-out at 10h |
| `openEditRequest(entryId)` | Opens modal for staff to request a time edit |
| `submitEditRequest(entryId)` | Posts edit request to `time_edit_requests` |
| `approveRequest(requestId)` | Admin approves an edit request; updates `time_entries` + sets request status to "approved" |
| `rejectRequest(requestId)` | Admin rejects an edit request; sets status to "rejected" |
| `approveAll()` | Bulk-approves all pending edit requests |
| `renderApprovals()` | Renders the pending approvals tab |
| `renderDashboard()` | Renders admin dashboard with hours summary per staff |
| `renderPayPeriod()` | Renders pay period view for the current user |
| `renderSettings()` | Renders staff settings management tab |
| `saveStaffConfig(staffId)` | Saves edits to a staff record in `staff_config` |
| `renderHUD()` | Renders the live HUD bar showing clocked-in staff with photos and elapsed time |
| `uploadPhoto(staffId)` | Handles photo upload for a staff member |
| `openManualModal(staffId)` | Opens modal for admin to manually create a time entry |
| `saveManualEntry()` | Saves a manually created time entry |
| `openAdjModal(entryId)` | Opens adjustment modal for an existing entry |
| `saveAdjustment()` | Saves an adjusted time entry |
| `openAddStaffModal()` | Opens modal to add a new staff member |
| `saveNewStaff()` | Creates a new staff record in `staff_config` |

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
