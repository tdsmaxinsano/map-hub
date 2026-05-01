# DependableCare Internal Staffing Portal — Project Reference

This document gives Claude full context to continue development without needing to re-read 21,000+ line files from scratch. Read this first, then read the relevant HTML file for the specific area you're working on.

---

## Project Overview

An internal web portal for **DependableCare**, a home health staffing agency. Two standalone HTML files — no framework, no build step, plain HTML/CSS/JS with Supabase and Mapbox. Files live in the **Map Project** folder of the user's selected workspace.

---

## Files

### `clinician-map.html` (~21,000 lines)
The main dashboard. Everything lives in this single file (HTML + CSS + JS).

**What it does:**
- Interactive Mapbox map showing clinician locations (work center or home)
- Sidebar with filterable clinician list (discipline, status, EMR, language filters)
- Clinician profile panel (edit address, work center, EMR, languages, ratings, restrictions, territories)
- ZIP code coverage tool — enter a ZIP, see which clinicians cover it
- Radius/lens tool — drop a pin, find clinicians within X miles
- Agency directory — home health agency profiles with map markers
- AI assistant — chat interface with map context awareness
- Referral overlay — sonar pins on map for open referrals
- Bulk import system (TherapyBoss CSV imports for clinicians, services, referrals)
- Territory drawing tool
- Ruler/distance measurement tool
- User management modal (admin only)
- Onboarding tour

**Two script blocks:**
- Script 1 (line ~6007–20502): Main app — `const elements`, `const appState`, `const map`, all core functions
- Script 2 (line ~20580–21321): Referral overlay, sidebar collapse toggle, onboarding tour, `escHtml()`

**Key `appState` properties:**
```
clinicians[]              — loaded clinician records
filteredClinicians[]      — after filters applied
agencies[]                — home health agency records
disciplineFilters         — Set of active disciplines (PT, PTA, OT, OTA, ST)
clinicianPinMode          — "work" | "home"
referralOverlayActive     — bool
referralOverlayMarkers[]  — Mapbox marker instances
referralOverlayData[]     — referral records
referralOverlayContacts[] — ALL contacts for loaded referrals (all response statuses)
refPanelOpenId            — UUID of currently open referral panel, or null
refPanelDisciplineSnapshot — Set — discipline filters before panel opened
```

**Key functions (Script 1):**
- `handleAuthSession(session)` — runs after login, loads all data
- `loadClinicians()` — fetches clinician_v2 + clinician_profiles, merges, renders
- `applyFilters()` — re-filters sidebar + map markers based on appState
- `syncDisciplineToggleState()` — syncs filter button UI to appState.disciplineFilters
- `runZipCoverageCheck()` — ZIP coverage lookup
- `selectCliniciansByRadius(center, miles)` — radius tool
- `openAgencyProfile(agencyId)` — opens agency panel
- `saveCurrentClinicianProfile()` — saves profile edits to Supabase
- `showToast(message, type, duration)` — toast notifications
- `getDisciplineColor(discipline)` — returns hex color for discipline badge
- `formatClinicianDisplayName(value)` — formats "LAST, FIRST" display names
- `escapeHtml(value)` — HTML escape (Script 1 version)

**Key functions (Script 2):**
- `toggleReferralOverlay()` — load/clear referral pins
- `loadReferralOverlay()` — fetches referrals + ALL contacts, has 3× retry for Supabase lock errors
- `renderReferralOverlay()` — creates sonar pin markers on map
- `openRefPanel(rid, r)` — opens fixed referral panel at top-left of map (left: 422px, top: 16px)
- `closeRefPanel()` — closes panel, restores discipline filters
- `refreshRefPanelContacts(refId)` — updates contact list + badge from local state
- `buildContactListHtml(contacts)` — renders contact status list HTML
- `refLogClinician(refId)` — logs a clinician contact to a referral
- `refOpenLens(lng, lat, address)` — drops lens pin at referral address
- `refAgencySearch(agencyName)` — opens agency profile from referral panel
- `escHtml(str)` — HTML escape (Script 2 version, used in referral overlay)
- `populateReferralDropdown()` — builds custom jump dropdown from appState.referralOverlayData; each row: agency (12 char + ellipsis, full name on hover), last name only, supervisor disciplines (PT/PTA→PT, OT/OTA→OT, ST→ST — handles "PT/PTA" slash format, no fixed min-width so badges sit naturally), city from address, age, status chip
- `clearReferralDropdown()` — hides and empties the jump dropdown
- `toggleRefJumpDropdown()` — opens/closes the jump dropdown panel
- `closeRefJumpDropdown()` — closes jump dropdown, resets state
- `handleRefJumpRow(r)` — on row select: closes dropdown, flies map, opens panel, drops lens
- `openQuickAddReferral()` — opens quick-add modal, resets form; fields: patient name, agency typeahead, address Mapbox typeahead, discipline pills
- `closeQuickAddReferral()` — closes modal
- `filterQarefAgencies(query)` — typeahead filter against appState.agencies
- `selectQarefAgency(name)` — confirms agency selection
- `qarefAddressInput(query)` — debounced 300ms Mapbox geocoding typeahead; min 3 chars
- `selectQarefAddress(idx, el)` — confirms address + stores coords in _qarefAddressCoords (required before save)
- `toggleQarefDisc(btn)` — toggles discipline pill on/off with discipline color
- `submitQuickAddReferral()` — validates patient_name (NOT NULL), agency, _qarefAddressCoords; inserts to Supabase, reloads overlay

---

### `referrals.html` (~varies)
The referral board. Separate standalone file.

**What it does:**
- Table view of all referrals with expand/collapse rows
- Referral contacts shown per referral with status
- Audit button — checks clinician restrictions, DNR status, active status; shows star ratings
- Delete button with confirmation (permanently deletes referral + all contacts)
- New referral form with agency combobox (sources from `home_health_agencies` table, typeahead search)
- Mapbox map showing referral address pins
- Filter by status

**Key variables:**
- `db` — Supabase client
- `allReferrals[]` — loaded referral records
- `allContacts[]` — loaded referral_contacts records
- `expandedId` — currently expanded referral row ID
- `_agencyNames[]` — loaded agency names for combobox
- `window._auditCache` — persists audit results across re-renders

---

## Integrations & Credentials

### Supabase
- **URL:** `https://jpemlcuxjvynlbeygukb.supabase.co`
- **Anon key:** hardcoded in both files (search `supabaseKey` or `SUPABASE_KEY`)
- **Auth:** Cookie-based storage via custom `cookieAuthStorage` object in clinician-map.html (survives refresh, not blocked by tracking prevention)
- **RLS:** Enabled. DELETE policies exist on `referrals` and `referral_contacts` using `auth.role() = 'authenticated'`
- **Realtime:** Clinician updates use Supabase realtime subscription (`setupClinicianRealtime()`)

### Mapbox
- **Access token:** `pk.eyJ1IjoiZGl6dG9ueTY3IiwiYSI6ImNtbjVjNW1seTA4dWsycXBpbjRreHVoOHQifQ.7wgw3ocLrvjEmpKdx-vP1A`
- **Version:** v3.0.1 in clinician-map.html, v3.3.0 in referrals.html
- **Used for:** Geocoding (address → lat/lng), map rendering, markers, radius search, territory polygons

### SendGrid
- Used for email notifications — check file for API key location

---

## Supabase Tables

| Table | Purpose |
|---|---|
| `clinician_v2` | Core clinician records (name, discipline, address, lat/lng, status, EMR, zip coverage) |
| `clinician_profiles` | Extended profile data (restrictions, do_not_rehire, star rating, languages, notes, work center overrides) |
| `clinician_zip_coverages` | ZIP code coverage rows per clinician |
| `clinician_photos` | Clinician photo storage |
| `clinician_profile_languages` | Language options per clinician |
| `clinician_profile_status_log` | Status change history |
| `clinician_profile_versions` | Profile version history |
| `home_health_agencies` | Agency directory (name, address, phone, fax, email, lat/lng, showOnMap, notes, restrictions) |
| `referrals` | Open referral records (patient_name, address, lat/lng, agency, disciplines[], referral_date, status) |
| `referral_contacts` | Clinicians logged per referral (referral_id, clinician_name, discipline, response: "waiting"/"accepted"/"declined") |
| `language_options` | Shared language options list |
| `user_roles` | User role assignments (user_id, role: "admin"/"editor"/"readonly") |
| `therapy_boss_*` | TherapyBoss import staging tables (completed services, zip coverage, referrals) |
| `therapy_boss_address_geocode_cache` | Cached geocode results for import addresses |

---

## User Roles & Auth

Three roles stored in `user_roles` table:
- **admin** — full access including user management, bulk import, all edits
- **editor** — can edit clinicians and referrals, cannot manage users
- **readonly** — view only, no edits (new signups default to this)

CSS classes control visibility:
- `.edit-only` — hidden in readonly-mode
- `.admin-only` — hidden in readonly-mode AND editor-mode
- `body.readonly-mode` / `body.editor-mode` — applied by `applyRoleMode(role)`

---

## Referral Overlay — How It Works

The referral overlay shows open referrals as sonar (pulsing) pins on the map.

**Pin appearance:**
- Color reflects age: orange (fresh) → amber (3+ days) → red (5+ days)
- Pulse speed reflects urgency
- Badge (navy circle) shows total contact count for that referral

**Panel behavior:**
- Clicking a pin opens a **fixed panel** pinned to top-center of `.map-panel`
- Panel stays open during all map interactions (pan, zoom, lens tool)
- Discipline filter auto-isolates to the referral's first discipline on open
- Discipline filter restores to pre-panel state on close
- Closing only via ✕ button (`closeRefPanel()`)
- Clicking a different pin while one is open → toast: "Close the current referral first to switch"

**Contact list in panel:**
- Shows ALL contacts (not just accepted) with status chips
- 🟡 Pending / 🟢 Accepted / 🔴 Declined
- Live updates after Quick Log (updates local state first, then refreshes DOM)

**Known issue — Supabase lock conflicts:**
On page load, the auth token refresh uses a "steal" lock that aborts concurrent Supabase requests. `loadReferralOverlay()` handles this with 3× retry logic (1.2s, 2.4s delays). Other loaders (clinicians, agencies) may also show AbortErrors on first load — refreshing the page resolves this.

---

## Layout & CSS Architecture (clinician-map.html)

```
body (flex column)
  .top-toolbar          ← moved here by JS IIFE at runtime (originally inside .map-panel)
  #app-shell (flex row)
    aside.sidebar       ← collapsible via .sidebar-collapsed class, width transition
    main.map-panel      ← position: relative, flex column
      button.sidebar-collapse-btn   ← absolute, left edge of map-panel
      div#ref-fixed-panel           ← absolute, left: 422px, top: 16px (just right of coverage panel)
      div.map-stage (flex: 1)       ← contains #map div
        div#map                     ← Mapbox canvas
```

**Sidebar collapse:**
- Toggle: `toggleSidebarCollapse()` — adds/removes `.sidebar-collapsed` on `#app-shell`
- Button text: ◀ (expanded) / ▶ (collapsed)
- After collapse: `map.resize()` called after 280ms transition
- `#ref-fixed-panel` uses `left: 422px; top: 16px` — positioned just to the right of `.floating-status-panel` (which is `left:16px; width:392px`). Both panels are `position:absolute` inside `.map-panel` so they track sidebar collapse together naturally

---

## Common Gotchas

- **`escHtml` vs `escapeHtml`** — two different functions. `escapeHtml()` is in Script 1, `escHtml()` is in Script 2. Use the right one for the scope you're in.
- **`display: "block"` not `""`** — agency dropdown uses `style.display = "block"` explicitly; `""` reverts to CSS `display:none`
- **Agency dropdown is `position:fixed`** — uses `getBoundingClientRect()` to escape modal `overflow:auto` clipping
- **Script 2 can access Script 1 `const` variables** — `elements`, `appState`, `map`, `supabaseClient` are all accessible from Script 2 since they're at the top level of a classic script tag
- **`flatMap` on disciplines** — always guard with `(r.disciplines || [])` before calling `.flatMap()`
- **`map.resize()` after sidebar toggle** — required or the map canvas doesn't fill correctly
- **Markers need `flex:1` on `.map-stage`** — if map has 0 height, check this first
- **`#map-instructions` is hidden** — `.map-overlay` has `display:none`; the element still exists in the DOM so JS references don't break, but the tooltip bar is not visible
- **`_qarefAddressCoords`** — must be set (by selecting from typeahead) before save; submit blocks if null
- **Referral jump dropdown** — `#ref-jump-cell` hidden until overlay loads; button label shows count e.g. "2 open referrals ▾"; `_refJumpOpen` tracks open state; click-outside closes via document listener
- **Quick add referral** — fields: patient_name (NOT NULL in DB), agency (typeahead from appState.agencies), address (Mapbox geocoding typeahead, debounced 300ms), disciplines (colored toggle pills). On save: inserts to Supabase, reloads overlay
- **Discipline colors** — `{ PT: "#2463eb", PTA: "#1e9b58", OT: "#7c3aed", OTA: "#ef7d23" }` (ST falls back to #6b7280)

---

## Development Tips

- **Start new sessions per feature** — the file is 21,000+ lines; focused sessions crash less
- **Read this file first, then read the specific section** of the HTML file you need
- **Syntax check JS additions** with: `node --check script.js`
- **After any edit, check** that `const elements` and `const appState` references still work in Script 2
