# DependableCare Portal — Project Index

This is the master reference for the DependableCare internal staffing portal. Always read this file first, then read the specific CLAUDE file for the area you are working on.

---

## Project Structure

All files are standalone HTML/CSS/JS — no framework, no build step. They share the same Supabase project and Mapbox token.

| File | Purpose | Reference Doc |
|---|---|---|
| `clinician-map.html` | Main map dashboard — clinician locations, filters, referral overlay, AI assistant (~21,000 lines) | `CLAUDE-map.md` |
| `referrals.html` | Referral board — table view, contacts, audit, new referral form | `CLAUDE-referrals.md` |
| `time-tracker.html` | Time tracking — clock in/out, pay periods, approvals, HUD | `CLAUDE-timetracker.md` |
| `compliance.html` | Compliance dashboard — not yet fully documented | (read the file directly) |
| `index.html` | Portal home / nav hub | (simple file, read directly if needed) |

---

## Shared Credentials

### Supabase
- **URL:** `https://jpemlcuxjvynlbeygukb.supabase.co`
- **Anon key:** hardcoded in each file (search `supabaseKey`)
- **Auth:** Cookie-based in clinician-map.html; localStorage-based in others
- **RLS:** Enabled on all tables

### Mapbox
- **Access token:** `pk.eyJ1IjoiZGl6dG9ueTY3IiwiYSI6ImNtbjVjNW1seTA4dWsycXBpbjRreHVoOHQifQ.7wgw3ocLrvjEmpKdx-vP1A`
- **Used in:** clinician-map.html (v3.0.1), referrals.html (v3.3.0)

---

## Shared Supabase Tables

| Table | Used By |
|---|---|
| `clinician_v2` | clinician-map |
| `clinician_profiles` | clinician-map, referrals (audit) |
| `clinician_zip_coverages` | clinician-map |
| `home_health_agencies` | clinician-map, referrals |
| `referrals` | clinician-map (overlay), referrals |
| `referral_contacts` | clinician-map (overlay), referrals |
| `staff_config` | time-tracker |
| `time_entries` | time-tracker |
| `time_edit_requests` | time-tracker |
| `user_roles` | all files |
| `language_options` | clinician-map |
| `therapy_boss_*` | clinician-map (bulk import) |

---

## User Roles

Three roles stored in `user_roles` (user_id, role):
- **admin** — full access including user management, bulk import, settings
- **editor** — can edit clinicians and referrals, cannot manage users
- **readonly** — view only (default for new signups)

---

## How to Start a Session

1. Read this file (`CLAUDE.md`) for project overview
2. Read the specific CLAUDE file for the area you're working on (e.g., `CLAUDE-map.md`)
3. Read only the relevant section of the HTML file using line offsets if needed

**Always update the relevant CLAUDE file at the end of the session** with any new functions, schema changes, or completed features. Ask: "Update the CLAUDE file with what we built today."

---

## Pending Work (as of last update)

- **clinician-map.html** — performance optimizations discussed (GeoJSON layers, virtual scroll, staggered data load) — not yet implemented
- **time-tracker.html** — Task #4: time edit approval system + 10hr hard stop (partially built, needs testing/polish)
- **compliance.html** — not yet explored or documented
- **Portal shell** — eventual goal is a unified iframe shell in `index.html` so all tools feel like one app
