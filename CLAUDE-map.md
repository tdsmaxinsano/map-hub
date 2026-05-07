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
- `loadClinicians()` — fetches clinician_v2 + clinician_profiles, merges, renders; calls `showClinicianLoadBar()` at start, `hideClinicianLoadBar()` on finish/error
- `applyFilters()` — re-filters sidebar + map markers based on appState
- `syncDisciplineToggleState()` — syncs filter button UI to appState.disciplineFilters
- `runZipCoverageCheck()` — ZIP coverage lookup
- `selectCliniciansByRadius(center, miles)` — radius tool; heavy DOM work (labels, sidebar, coverage) debounced 80ms via `_lensHeavyTimer`; ZIP snap debounced 350ms via `_snapZipTimer`
- `openAgencyProfile(agencyId)` — opens agency panel
- `saveCurrentClinicianProfile()` — saves profile edits to Supabase
- `showToast(message, type, duration)` — toast notifications
- `getDisciplineColor(discipline)` — returns hex color for discipline badge
- `formatClinicianDisplayName(value)` — formats "LAST, FIRST" display names
- `escapeHtml(value)` — HTML escape (Script 1 version)
- `showClinicianLoadBar()` / `hideClinicianLoadBar()` — shows/hides animated shimmer bar under Clinicians toolbar button
- `showServicesLoadBar()` / `hideServicesLoadBar()` — shows/hides animated shimmer bar under Services toolbar button
- `syncClinicianVisibilityToggle()` — syncs `#toolbar-toggle-clinicians` active class to `appState.showClinicians`
- `syncCompletedServiceVisibilityToggle()` — syncs `#toolbar-toggle-services` active class to `appState.showCompletedServices`
- `ensureClinicianLayer()` — sets up GeoJSON source `"clinician-pins"` + 7 WebGL layers on map style load
- `buildClinicianFeature(clinician)` — returns GeoJSON Feature for one clinician (id, discipline, status, locationSource, isNew)
- `rebuildClinicianGeoJSON()` — rebuilds full GeoJSON from `appState.clinicians`, calls `map.getSource("clinician-pins").setData(...)`
- `applyClinicianLayerFilters()` — applies GPU-side `map.setFilter()` to all clinician layers using visible/selected/focused ID arrays; guards on source + layer existence
- `getVisibleClinicianIds()` — returns union of `lensSpotlightIds` (if lens active) and `filteredIds` (if showClinicians)
- `clearFocusedDomMarker()` — removes the single focused DOM marker from map and `appState.markersById`
- `syncAllMarkerVisuals()` — calls `applyClinicianLayerFilters()` + `updateMarkerVisual()` for focused DOM marker only

**Key functions (Script 2):**
- `toggleReferralOverlay()` — load/clear referral pins
- `loadReferralOverlay()` — fetches referrals + ALL contacts, has 3× retry for Supabase lock errors
- `renderReferralOverlay()` — calls `rebuildReferralGeoJSON()` + `startReferralSonarTick()` to show pins via WebGL; also binds one-time ZIP capture-phase intercept
- `openRefPanel(rid, r)` — opens fixed referral panel at top-left of map (left: 422px, top: 16px)
- `closeRefPanel()` — closes panel, restores discipline filters
- `refreshRefPanelContacts(refId)` — updates contact list + badge from local state
- `buildContactListHtml(contacts)` — renders contact status list HTML
- `refLogClinician(refId)` — logs a clinician contact to a referral
- `refOpenLens(lng, lat, address)` — drops lens pin at referral address
- `refAgencySearch(agencyName)` — opens agency profile from referral panel
- `escHtml(str)` — HTML escape (Script 2 version, used in referral overlay)
- `ensureReferralLayer()` — sets up GeoJSON source `"referral-pins"` + 5 WebGL layers: `referral-sonar-2`, `referral-sonar-1` (pulse rings), `referral-dot` (colored core), `referral-badge-bg` (navy circle), `referral-badge-text` (count). Called in `map.on("style.load")`.
- `buildReferralFeature(r, contactCount)` — returns GeoJSON Feature with `id`, `ageBucket` ("fresh"/"amber"/"red"), `count` props
- `rebuildReferralGeoJSON()` — rebuilds full FeatureCollection from `appState.referralOverlayData`, calls `map.getSource("referral-pins").setData(...)`
- `startReferralSonarTick()` — `requestAnimationFrame` loop; calls `map.setPaintProperty` each frame to animate `circle-radius` + `circle-opacity` on both sonar layers using age-bucket pulse periods (red 1.1s / amber 1.7s / fresh 2.4s); layer-2 offset 1200ms for double-pulse; loop self-terminates when `appState.referralOverlayActive` is false
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
- Used for sending reactivation request emails to the hiring manager
- API key stored as Supabase Edge Function secret: `SENDGRID_API_KEY`
- Verified sender: `info@dependablecarestaffing.com` (stored as `SENDGRID_FROM_EMAIL` secret)
- Recipient: `dcsrep01.dependablecare@gmail.com` (stored as `HIRING_MANAGER_EMAIL` secret)
- Secrets managed via Supabase Dashboard → Edge Functions → send-reactivation-email → Secrets

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

**Referral pins are GeoJSON WebGL layers (not DOM markers):**
`renderReferralOverlay()` no longer creates DOM markers. Pins render via source `"referral-pins"` and 5 WebGL layers set up by `ensureReferralLayer()`. This permanently eliminates zoom-drift — DOM markers reposition via JS rAF and can lag behind the WebGL canvas during zoom; GeoJSON layers render inside the canvas and scale natively. The pulse animation is driven by `startReferralSonarTick()` using `setPaintProperty` each frame. Click handling is via `map.on("click", "referral-dot")` in `bindEvents()`.

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
- **`_zipClearedByUser` flag** — set `true` when user clicks the ZIP clear button; suppresses `snapZipToLensLocation` on subsequent lens moves so ZIP doesn't silently re-populate after being cleared
- **Default startup zoom** — 70% (set via `var currentZoom = 70` in the zoom IIFE, not 100%)
- **Clinician markers are GeoJSON WebGL layers** — not DOM markers. 7 layers: `clinician-circles`, `clinician-inactive`, `clinician-disc-label`, `clinician-paused-ring`, `clinician-selected-ring`, `clinician-hw-label`, `clinician-new-star`. Only the focused clinician gets a DOM marker (via `buildMarker()`). Filters applied via `applyClinicianLayerFilters()` using `map.setFilter()` — no GeoJSON rebuild on filter change.
- **Referral pins are also GeoJSON WebGL layers** — not DOM markers. 5 layers on source `"referral-pins"`: `referral-sonar-2`, `referral-sonar-1`, `referral-dot`, `referral-badge-bg`, `referral-badge-text`. Pulse animation driven by `startReferralSonarTick()` rAF loop via `setPaintProperty`. Click via `map.on("click","referral-dot")`. Badge updates via `rebuildReferralGeoJSON()` in `refreshRefPanelContacts()`.
- **Toolbar load bars** — `.layer-btn-wrap` wraps each toggle button as a column; `.layer-load-bar` is a 3px green shimmer bar (CSS animation `layerBarSlide`). IDs: `#clinician-load-bar`, `#services-load-bar`. Add `.loading` class to show, remove to hide.
- **User chip is first in toolbar** — `.toolbar-cell` with `#toolbar-user-chip`, `#toolbar-logout`, `#realtime-dot`, `#toolbar-manage-users` is the first child of `.toolbar-row`

---

## Reactivation Request Feature

When a clinician's status is **Inactive**, a "📧 Send Reactivation Request" button appears in their profile panel. Clicking it opens a compose modal; submitting sends an email to the hiring manager via a Supabase Edge Function.

### UI Elements
- `#profile-reactivation-btn` — button, `.edit-only`, shown only when `currentStatus === "Inactive"` (toggled via `.visible` class in `renderProfileStatus()` ~line 13585)
- `#reactivation-modal` — compose modal (opened by `openReactivationModal()`, closed by `closeReactivationModal()`)
- `#reactivation-who` — shows clinician name, discipline, and inactive-since date
- `#reactivation-note` — optional note textarea
- `#reactivation-send` — send button (calls `submitReactivationRequest()`)
- `#profile-reactivation-stamp` — date stamp div shown below button after a request is sent ("📨 Last requested: May 5, 2026 3:42 PM")
- `#profile-reactivation-stamp-date` — span inside stamp with formatted timestamp

### Key JS Functions
- `openReactivationModal()` — uses `getCurrentProfileClinicianRecord()` to get clinician; populates modal with name/discipline/inactive-since
- `closeReactivationModal()` — removes `.open` class from modal
- `submitReactivationRequest()` — POSTs to Edge Function, then saves `reactivationRequestedAt` ISO timestamp to `profile_tags` via Supabase upsert, updates in-memory clinician, calls `renderReactivationStamp()`
- `renderReactivationStamp(clinicianId)` — reads `profile_tags.reactivationRequestedAt` from clinician record, shows/hides stamp using `formatStatusHistoryTimestamp()` for formatting

### Supabase Edge Function
- **Name:** `send-reactivation-email`
- **Project ref:** `jpemlcuxjvynlbeygukb`
- **File:** `supabase/functions/send-reactivation-email/index.ts`
- **Deployed via:** Supabase CLI (`supabase functions deploy send-reactivation-email --project-ref jpemlcuxjvynlbeygukb`)
- **Payload:** `{ clinicianName, discipline, inactiveSince, note, senderName, senderEmail }`
- **reply_to:** set to the logged-in user's email so hiring manager can reply directly

### Timestamp Persistence
- Stored as `profile_tags.reactivationRequestedAt` (ISO string) in the `clinician_profiles` table `tags` JSON column
- No schema change required — `tags` already holds arbitrary metadata
- Upserted on successful send; in-memory `appState.clinicians` record updated immediately for instant UI refresh

---

## TherapyBoss Import — Sync Update Mode + ZIP Coverage Preview + Email Reports

### Three Import Modes (Clinician Master)
The clinician_master import has three modes selectable via buttons (`data-clinician-import-mode`):
- **`full_initial_load`** — Upserts all clinicians, including new + existing. Overwrites name, discipline, address, phone, email. Use only for first roster baseline.
- **`additions_only`** (default) — Skips existing clinicians entirely. Only new ones get created. Map profile remains source of truth.
- **`status_update`** (labeled "Sync Update") — On matched clinicians ONLY: syncs status (Active/Inactive), address, lat/lng, zip, and phone. Other fields (name, discipline, EMR, ratings, etc.) untouched. Unmatched names skipped.

### Sync Update Mode Logic
- Mode set via `setClinicianImportMode("status_update")` → `appState.clinicianImportMode`
- Inside `uploadClinicianMasterImportToSupabase()` row loop: dedicated branch updates `clinician_v2` (status, active, address, zip, lat, lng) + `clinician_profiles` (status, phone)
- Sparse update: only writes fields that actually differ from current portal state
- In-memory `appState.clinicians` record updated immediately so map refreshes without `loadClinicians()` reload

### ZIP Coverage Import — Replace All Per Clinician
- `uploadClinicianZipCoverageImportToSupabase()` deletes ALL existing coverage for matched clinicians, then inserts new rows
- Preferred ZIPs are NOT manually editable in the portal (they come only from imports), so replace-all is safe
- After commit, `clinician_v2.preferred_zips` is updated with comma-separated zip summary
- `clinician_zip_coverages` columns: `clinician_id`, `zip_code`, `discipline`, `memo`, `clinician_name_raw`, `source_system`, `import_batch_id`, `updated_at`

### Preview/Confirmation Modals
Both Sync Update and ZIP Coverage now show a preview modal BEFORE committing — single shared `#status-preview-modal` HTML repurposed for each flow.

**`showStatusUpdatePreview()`** — Sync Update preview:
- Computes per-clinician diff: status flip, phone change, address change, zip change
- Renders one card per changed clinician with emoji-prefixed change list
- Sections: Changes / Not Found in Portal
- Returns Promise<bool> — true = confirm, false = cancel

**`showZipCoveragePreview()`** — ZIP Coverage preview:
- Compares incoming zip|discipline keys against clinician's current `zip_coverages`
- Per-clinician card with green `+ Add`, red `− Remove`, amber `~ Memo changed` lines
- Summary: `+12 · −3 · ~1 across 8 clinicians · 2 unmatched`
- Returns Promise<bool>

Both preview functions use `escapeHtml()` for all user content. The modal title is swapped via `modal.querySelector("h3").textContent` and restored on cleanup.

### Import Report Email
After successful Sync Update or ZIP Coverage import, an HTML report email is automatically sent.

**Edge Function:** `send-import-report` (`supabase/functions/send-import-report/index.ts`)
- **Recipients:** TO = logged-in user's email; CC = comma/semicolon-separated list from `IMPORT_REPORT_CC_EMAIL` secret
- **Payload:** `{ reportType, summary, sectionsHtml, runByName, runByEmail }`
- **Reuses existing secrets:** `SENDGRID_API_KEY`, `SENDGRID_FROM_EMAIL`
- **Optional secret:** `IMPORT_REPORT_CC_EMAIL` — supports multiple addresses, e.g. `"a@x.com, b@y.com, c@z.com"`

**Client flow:**
1. Preview function builds report payload (`buildSyncReport()` or `buildZipReport()`) inside its scope
2. On confirm, payload stored in module-level `_pendingImportReport` var
3. After successful upload in `uploadImportToSupabase()`, `sendImportReport(_pendingImportReport)` is called and the var cleared
4. Email failure does NOT roll back import — only a warning toast appears

**Helper:** `sendImportReport(payload)` — POSTs to the edge function with logged-in user as `runByEmail`, shows success toast "Report emailed."

---

## TherapyBoss Screenshot Import — AI Scan via Edge Function

The "Import from TherapyBoss" modal lets staff drop a screenshot of TB referrals and have GPT-4o vision parse it into structured rows. The OpenAI key is **never sent to the browser** — it lives only as a Supabase Edge Function secret.

### Edge Function
- **Name:** `tb-scan-image` (`supabase/functions/tb-scan-image/index.ts`)
- **Project ref:** `jpemlcuxjvynlbeygukb`
- **Reads secret:** `OPENAI_API_KEY` (shared org-wide; same key used by AI assistant)
- **Payload:** `{ imageBase64, prompt? }` — prompt has a sensible TB-specific default if omitted
- **Calls:** OpenAI `/v1/chat/completions` with `model: gpt-4o`, `max_tokens: 4096`, vision input
- **Returns:** raw OpenAI response (client extracts `choices[0].message.content` and JSON-parses)
- **JWT verification:** ON — only signed-in portal users can invoke

### Client Flow
- `runTbScan()` (~line 23710) gets the user's session token, POSTs `_tbImageBase64` to the edge function, parses the returned JSON array of referrals, calls `renderTbPreview()`
- No API key prompt or storage in browser — modal shows static "🟢 AI Scanner Ready" indicator (`#tb-key-status`, `#tb-key-label`)
- Vestigial `loadTbApiKey()` stub remains (returns `""`) to avoid breaking other call sites; `saveTbApiKey()`, `updateTbKeyStatus()`, `toggleTbKeyEdit()`, `saveTbApiKeyFromInput()` were removed

### Why the Migration
Previously each user entered their own OpenAI key, ostensibly saved to a `staff_config.openai_api_key` row. The save was wrapped in `try { ... } catch(e) {}` that swallowed Supabase RLS errors silently — so localStorage was the only reliable cache. Browser eviction (Safari ITP, Chrome storage purge) wiped localStorage overnight, requiring re-entry. Moving the key server-side eliminated:
- The wipe issue (no browser storage involved)
- Per-user billing fragmentation (one shared org key)
- Key exposure to the browser (security win)

---

## Development Tips

- **Start new sessions per feature** — the file is 21,000+ lines; focused sessions crash less
- **Read this file first, then read the specific section** of the HTML file you need
- **Syntax check JS additions** with: `node --check script.js`
- **After any edit, check** that `const elements` and `const appState` references still work in Script 2
