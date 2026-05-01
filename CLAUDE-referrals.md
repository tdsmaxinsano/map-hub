# DependableCare Referral Board — Project Reference

This document gives Claude full context to continue development on `referrals.html` without re-reading the full file from scratch. Read this first, then read the relevant section of the HTML file for the specific area you're working on.

---

## Project Overview

`referrals.html` is a standalone referral management board for **DependableCare**. It is a single HTML file (no framework, no build step) using Supabase and Mapbox. It lives in the **Map Project** folder alongside `clinician-map.html`.

---

## File

### `referrals.html`

**What it does:**
- Table view of all referrals with expand/collapse rows
- Per-referral contact list showing clinicians logged with status chips
- Audit button — checks clinician restrictions, DNR status, active status; shows star ratings
- Delete button with confirmation (permanently deletes referral + all contacts)
- New referral form with agency combobox (typeahead sourced from `home_health_agencies` table)
- Mapbox map showing referral address pins
- Filter by referral status
- Nav link back to `index.html` and to `compliance.html`

---

## Key Variables

| Variable | Purpose |
|---|---|
| `db` | Supabase client instance |
| `allReferrals[]` | All loaded referral records |
| `allContacts[]` | All loaded referral_contacts records |
| `expandedId` | UUID of currently expanded referral row (or null) |
| `_agencyNames[]` | Loaded agency names for new referral combobox |
| `window._auditCache` | Persists audit results across re-renders (keyed by referral ID) |

---

## Key Functions

| Function | Purpose |
|---|---|
| `doSignIn()` | Supabase email/password sign-in |
| `doSignOut()` | Sign out + redirect |
| `loadAll()` | Entry point after auth — calls loadReferrals then loadAgencyNames |
| `loadReferrals()` | Fetches referrals + contacts from Supabase, populates allReferrals/allContacts |
| `applyFilters()` | Filters allReferrals by status, then calls renderTable |
| `renderTable()` | Renders the full referral table DOM |
| `renderStars(n)` | Returns star HTML for a given rating number |
| `renderDetailInner(refId)` | Renders expanded row content (contacts, audit, add contact form) |
| `wireAddContactForm(refId)` | Wires up the add-contact input for a given referral row |
| `addContact(refId)` | Posts new contact to referral_contacts, refreshes row |
| `updateContactResponse(contactId, newStatus)` | Updates a contact's response field in Supabase |
| `checkAutoStaffed(refId)` | Checks if any contact has accepted; auto-sets referral status to "staffed" |
| `auditReferralClinicians(refId)` | Fetches clinician_profiles for each contact and renders audit results |
| `removeContact(contactId, refId)` | Deletes a contact from referral_contacts |
| `updateReferralStatus(refId, newStatus)` | Updates referral status field in Supabase |
| `toggleExpand(refId)` | Expands or collapses a referral row |
| `deleteReferral(refId)` | Deletes referral + all contacts with confirmation |
| `openNewReferral()` | Shows the new referral modal |
| `loadAgencyNames()` | Fetches agency names for combobox typeahead |
| `saveNewReferral()` | Validates + posts new referral to Supabase |
| `setupRealtime()` | Supabase realtime subscription for live referral updates |
| `renderMapPins()` | Renders Mapbox markers for all referral addresses |
| `saveReferralDisciplines(refId)` | Reads PT/PTA, OT/OTA, ST checkboxes from expanded row, updates `disciplines[]` in Supabase, refreshes row by toggling expand |

---

## Contact Response Status Values

```js
const RESPONSE_LABELS = {
  waiting:           "Waiting",
  accepted:          "Accepted",
  accepted_solo:     "Accepted (Solo)",
  declined:          "Declined",
  declined_full:     "Declined – Full",
  declined_too_far:  "Declined – Too Far",
  on_hold:           "On Hold",
  on_leave:          "On Leave",
  restaff:           "Needs Restaff",
  already_assigned:  "Already Assigned"
};
```

---

## Supabase Tables Used

| Table | Usage |
|---|---|
| `referrals` | Main referral records (patient_name, address, lat/lng, agency, disciplines[], referral_date, status) |
| `referral_contacts` | Clinicians logged per referral (referral_id, clinician_name, discipline, response, created_at) |
| `clinician_profiles` | Read during audit (restrictions, do_not_rehire, star_rating, active status) |
| `home_health_agencies` | Source for agency combobox in new referral form |

---

## Integrations & Credentials

### Supabase
- **URL:** `https://jpemlcuxjvynlbeygukb.supabase.co`
- **Anon key:** hardcoded in file (search `supabaseKey`)
- **Auth:** Email/password, session stored in localStorage
- **RLS:** DELETE policies on `referrals` and `referral_contacts` require `auth.role() = 'authenticated'`

### Mapbox
- **Access token:** `pk.eyJ1IjoiZGl6dG9ueTY3IiwiYSI6ImNtbjVjNW1seTA4dWsycXBpbjRreHVoOHQifQ.7wgw3ocLrvjEmpKdx-vP1A`
- **Version:** v3.3.0
- **Used for:** Map display of referral address pins

---

## Layout & UI Notes

- Single-page, table-based layout with expand/collapse rows
- Status filter buttons at top (All / Open / Staffed / Cancelled)
- Expanded row shows: contacts table with status dropdowns, audit results section, add contact form
- New referral modal is a full-screen overlay
- Audit results are cached in `window._auditCache` — survives row collapse/re-expand without re-fetching

---

## Common Gotchas

- **`_auditCache` is on `window`** — survives re-renders. Reset it on full page reload only.
- **`disciplines[]` is an array** — guard with `(r.disciplines || [])` before iterating
- **Agency combobox is typeahead** — uses `_agencyNames[]` loaded from `home_health_agencies` table
- **Delete is permanent** — deletes referral + all referral_contacts in one transaction
- **Realtime subscription** — `setupRealtime()` uses Supabase realtime; refresh data on INSERT/UPDATE/DELETE events
- **`checkAutoStaffed`** — automatically marks referral as "staffed" if any contact status is "accepted" or "accepted_solo"
- **Disciplines storage format** — stored as `["PT/PTA", "OT/OTA", "ST"]` combined strings (not separate PT/PTA entries). The edit checkboxes in the expanded row use this same format. The clinician-map dropdown normalizes by splitting on `/`
- **No `showToast` in referrals.html** — use `alert()` for errors; no toast utility exists here
- **Disciplines edit** — bottom of expanded row has PT/PTA · OT/OTA · ST checkboxes pre-checked from current data + Save button calling `saveReferralDisciplines()`

---

## Navigation

This file links to:
- `index.html` — portal home
- `clinician-map.html` — main map dashboard
- `compliance.html` — compliance dashboard

---

## Development Tips

- **Read `CLAUDE.md` (clinician-map) first** for shared credentials (Supabase URL, Mapbox token) and overall project context
- **Check `window._auditCache`** in console if audit results seem stale
- **Supabase AbortError on load** — same "steal" lock issue as clinician-map.html; add retry logic if adding new Supabase fetches on page load
- **After any schema change** to `referral_contacts`, update `RESPONSE_LABELS` and all status chip rendering logic
