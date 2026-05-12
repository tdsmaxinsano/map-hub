# Kanban Task Board + Team Chat — Reference

Covers `kanban.html` and the shared `chat-widget.js`. Both built May 2026. Both standalone HTML/JS (same stack as the rest of the portal — no framework, no build step).

---

## kanban.html — Task Board (~2,100 lines)

### What it does
Multi-board kanban with drag/drop, SLAs, cross-page entity links, admin board management, and live realtime sync. Default boards: **Referrals** (`Open / Contacted / Confirmed / Done`), **Compliance** (`To Review / In Progress / Awaiting Doc / Resolved`), **General** (`To Do / Doing / Done`). Admins can edit/add/delete boards and columns.

### Schema
Three tables (created by `supabase/policies/02_kanban_tables.sql`):

- **`boards`** — `id, name, slug, icon, position, is_default`. Top-level workflows. Admin-edit only.
- **`board_columns`** — `id, board_id, name, position, is_done`. Per-board columns. `is_done = true` flags which column triggers `completed_at` and the auto-archive timer. Admin-edit only.
- **`tasks`** — `id, title, description, board_id, column_id, position, is_archived, linked_entity_type, linked_entity_id, linked_entity_label, created_by, assigned_to, due_at, sla_preset, created_at, updated_at, completed_at, archived_at`. All authenticated users CRUD.

`linked_entity_type` ∈ `{clinician, referral, compliance_item, agency, NULL}`. NULL = freestanding task. The `linked_entity_label` is a denormalized snapshot so the chip still renders if the linked entity is later deleted.

### Key JS state (in `kanban.html` script tag)
- `currentUser` — Supabase auth user
- `isAdmin` — boolean from `user_roles`; gates the ⚙ Boards and 👥 Names buttons
- `boards` / `columnsByBoardId` — schema cache, loaded via `loadBoardsAndColumns()`
- `tasks` / `archivedTasks` — task cache; `loadTasks()` for active, `loadArchivedTasks()` for archived
- `staffList` / `staffByUserId` — loaded via `db.rpc("list_staff")`. Powers the assign-to dropdown, card avatars, and dropdown color emojis.
- `activeBoardId`, `activeFilter`, `searchQuery`, `showArchived` — URL-driven filter state
- `realtimeChannel` — single channel watching `tasks`, `boards`, `board_columns`

### Key functions
- `loadBoardsAndColumns()` — fetches boards + columns; picks active board from URL `?board=slug` or default
- `loadStaffDirectory()` — RPC, populates `staffList`
- `loadTasks()` — fetches non-archived tasks, calls `renderBoard()`
- `renderBoard()` — re-renders the active board's columns + cards
- `buildCardEl(task)` — DOM for a single card. Title + SLA pill + 👤 Mine chip if assigned to current user + linked-entity chip + creator/assignee row with avatars + colored left-edge tint based on creator's color.
- `computeSla(task)` — returns `{tier, label}` for the SLA pill (green/amber/orange/red/gray)
- `handleCardDrop(evt)` — SortableJS callback. Updates `column_id` + `position` + (if dropped into is_done column) `completed_at`. Then `reflowColumn()` updates positions for all other cards in the destination column.
- `openTaskModal(task)` / `saveTask()` / `deleteTask()` — task modal
- `openManageBoards()` / `openEditBoard(boardId)` / `saveEditBoard()` / `deleteBoard()` — admin board management
- `openManageNames()` / `renderManageNamesList()` — admin staff profile management (display name + color + photo)
- `setupRealtime()` — subscribes to `tasks`, `boards`, `board_columns` postgres_changes; just re-fetches on any event (cheap because dataset is small)

### Cross-page integration
- **Clinician profile** has a "🗂️ + Task on this clinician" button (in `clinician-map.html`'s reactivation row). Calls `openKanbanTaskForCurrentClinician()` which opens kanban in a new tab with `?link_type=clinician&link_id=<id>&link_label=<name>` — the kanban auto-opens its modal pre-filled.
- The kanban respects URL params on load via `_pendingLink` and `maybeOpenWithPendingLink()`.
- Linked-entity chips on cards (📋 Smith, John) are clickable — `navigateToLinked()` jumps to the appropriate page (`clinician-map.html?clinician=<id>`, etc.)

### Admin gear icons
Two admin-only buttons in the top-right of the board tab strip:
- **⚙ Boards** — manage boards/columns (HTML `id="board-manage-btn"`, class `admin-only-hidden` until isAdmin check removes it)
- **👥 Names** — manage staff display names, colors, photos (`id="manage-names-btn"`)

Hidden via `.admin-only-hidden { display: none; }`. The class is removed in `launchApp()` after the role check.

### SLA presets
`1h / 4h / 24h / 3d / 1w / Custom (datetime-local) / None`. Stored as `sla_preset` (string) + `due_at` (timestamp). `computeSla()` derives the pill color from time remaining vs total SLA window:
- `>50%` of window remaining → green
- `25–50%` → amber
- `<25%` (still time) → orange
- `0%` (past due) → red `⚠ Overdue X days/hrs ago`
- Completed → gray, "Done X ago" — gray if on-time, red if late

`startSlaTicker()` — interval re-renders the board every 30s so SLA pills update without a fetch.

### Auto-archive
- Edge Function `tasks-auto-archive` (in `supabase/functions/tasks-auto-archive/index.ts`) flips `is_archived = true` on tasks whose `completed_at` is 7+ days old.
- Uses service-role key (default Supabase secret). Schedule via Supabase Dashboard cron `0 3 * * *`.
- Optional — kanban works without it; Done column just bloats over time.

### Known gotchas
- **Drag-and-drop reflow**: when a card moves between columns, `reflowColumn()` does N updates (one per card in destination column). Acceptable for typical board sizes (<100 cards/column). For larger boards, batch into a single SQL `UPDATE` with `unnest()`.
- **Cross-board task moves not supported in v1** — task is bound to one board. Adding "move to board…" is a v2 feature.
- **No comments / activity log** — also v2.
- **The realtime subscription on the kanban does a full re-fetch on any event** for simplicity. If many users are editing tasks at once, this could thrash. Move to per-row patching (mirror `setupClinicianRealtime`'s pattern) if it becomes a problem.

---

## chat-widget.js — Portal-Wide Team Chat (~640 lines)

### What it does
Old-school chat-room widget on every portal page (Map / Referrals / Time / Compliance / Kanban). Single channel, IRC-style format `[time] <user> message`, colored usernames, join/leave notices, online list, unread badge, sound ping, browser tab title flash.

### Inclusion
Each portal HTML file ends with:
```html
<script src="chat-widget.js"></script>
```
right before `</body>`. The Supabase JS library must already be loaded (it is — every portal page loads `supabase-js@2` for its own purposes).

### Self-injection
The widget is wrapped in an IIFE that:
1. Guards against double-injection (`window.__dcsChatWidgetLoaded`)
2. **Iframe-shell guard:** if `window.self !== window.top` it returns immediately. The shell's chat widget is the canonical one — tools inside iframes don't get a second copy. Tools accessed standalone still inject normally.
3. Waits for both `DOMContentLoaded` and `supabase.createClient` to be available
4. Creates its OWN Supabase client (does not rely on each page's variable name) using the same URL/key + `localStorage` storage → shares the SSO session
5. Injects a `<style>` block + `#dcs-chat-widget` div into the page
6. If the user isn't authenticated, the widget renders nothing (and listens via `onAuthStateChange` for sign-in)

### Key state
- `currentUser` — Supabase auth user
- `staffById` — display name + color + photo cache, loaded via `list_staff()` RPC
- `messages` — local cache (last ~50 + paginated older)
- `onlineUsers` — keyed by user_id, populated by Supabase Presence
- `unreadCount`, `isOpen`, `originalTitle` — UI state
- `realtimeChannel` (table=`chat_messages`) and `presenceChannel` (key=user_id) — separate Supabase channels

### Channels used
- **`team-chat-v1`** — postgres_changes on `chat_messages` (INSERT and DELETE)
- **`team-chat-presence`** — Supabase Presence for online users; each client `track()`s `{ user_id, email, name, online_at }`

### Presence join/leave debounce (refresh-spam fix)
Supabase Presence fires `leave` then `join` on every page refresh, iframe-tab-switch, or quick reload — which originally caused a flood of `— X joined —` / `— X left —` system messages in every other user's chat panel. The widget now:
1. On `leave`, schedules the "X left" message after a **25-second** debounce (`LEAVE_DEBOUNCE_MS`). If the same user rejoins inside that window, the timer is cleared and BOTH messages are suppressed → a refresh is invisible.
2. On `join`, a **60-second** per-user cooldown (`JOIN_COOLDOWN_MS`) suppresses initial-sync echo joins (Supabase fires `join` for already-present users when you first subscribe).
3. `appendSystemMessage` coalesces consecutive identical system messages — belt and suspenders against any race.

State variables: `pendingLeaveTimers` (`{user_id: timeoutId}`) and `recentlyAnnouncedJoin` (`{user_id: timestamp}`).

### Tab title flash + sound
- `setupTabVisibility()` — when document is hidden and a new message arrives (not from self), prefix `document.title` with `(N) `. Strip on focus.
- `playPing()` — Web Audio API two-tone blip (880Hz then 1320Hz). First ping might be silent due to browser autoplay policy; subsequent pings work after any user interaction.
- 🔔 / 🔕 mute toggle in the header; preference stored in `localStorage.dcs_chat_muted`.

### Format
Compact IRC-style:
```
[10:14a] <Maria> Smith referral covered, anyone?
[10:15a] <Erika> I'll take it
— John joined —
```
- Username colored using `colorFor(user_id)` — display_color from staff_config OR a deterministic fallback hash.
- System messages (join/leave) are italicized gray, centered.

### Realtime gotcha — IMPORTANT
**`chat_messages` MUST be added to the `supabase_realtime` publication** for messages to broadcast live. Without it, messages save to the DB but only show up on page reload. The migration `04_chat_messages.sql` does this via:
```sql
ALTER PUBLICATION supabase_realtime ADD TABLE public.chat_messages;
```
This is wrapped in a `DO` block guard so it's idempotent.

If you ever add another table that needs realtime, do the same — Supabase doesn't auto-add new tables to the publication.

### Data + RLS
All in `04_chat_messages.sql`:
- `SELECT` open to all authenticated
- `INSERT` only as self (`user_id = auth.uid()`)
- `UPDATE` / `DELETE` only own messages — schema supports edit/delete but the UI doesn't expose it yet

### Position
Bottom-LEFT (`left: 18px; bottom: 18px; z-index: 21`) — opposite of the AI Assistant (bottom-right, `z-index: 20`). Both can be open simultaneously without overlap.

### Out of scope (v1 → v2)
- Multiple channels
- DMs (direct messages)
- @mentions with notifications
- File / image uploads
- Read receipts
- Edit/delete message UI

---

## Staff directory (used by both kanban + chat)

`supabase/policies/03_staff_directory.sql` adds three columns to `staff_config`:
- `display_name TEXT` — friendly name (e.g. "Maria Lopez")
- `display_color TEXT` — hex from the 8-color portal palette (`#2463eb`, `#7c3aed`, `#ef4444`, `#f97316`, `#eab308`, `#22c55e`, `#92400e`, `#1e293b`)
- `photo_url TEXT` — URL to a headshot in the `staff-photos` bucket

### RPCs
- `list_staff()` — SECURITY DEFINER, returns directory for all authenticated users (bypasses `auth.users` RLS that would otherwise hide other users)
- `upsert_staff_profile(user_id, name, color, photo_url)` — admin-only. Treats NULL params as "leave unchanged"; empty-string treats as "explicit clear" (handled via NULLIF inside the function).
- `clear_staff_field(user_id, field)` — admin-only explicit NULL. Used when admin chooses the "unset" swatch (✕) on color picker, or when removing a photo.

### Storage
`staff-photos` bucket — public-read (so `<img src=...>` works without signed URLs), admin-write (RLS check on `user_roles.role = 'admin'`).

Photo file path convention: `<user_id>.<ext>` — overwriting on re-upload via `upsert: true`. After upload, the kanban appends `?t=<timestamp>` to bust browser caches.

### Color palette
8 named colors, hex + emoji circle:
| Name | Hex | Emoji |
|---|---|---|
| blue | `#2463eb` | 🔵 |
| purple | `#7c3aed` | 🟣 |
| red | `#ef4444` | 🔴 |
| orange | `#f97316` | 🟠 |
| yellow | `#eab308` | 🟡 |
| green | `#22c55e` | 🟢 |
| brown | `#92400e` | 🟤 |
| slate | `#1e293b` | ⚫ |

The emoji circles let the kanban assign-to dropdown show colors in `<select>` options without needing a custom dropdown component.

### Avatars
Both the kanban and chat use the same `avatarHtml(user_id, size)` helper:
- If `photo_url` is set → `<img>` circle
- Else → solid colored circle with the first letter of the display name
- Falls back to deterministic color hash (`fallbackColorFor(user_id)`) if no `display_color` is set, so different users still look different even before any admin setup

---

## Activation checklist (when re-deploying to a fresh DB)

1. Run all SQL migrations in order:
   - `01_phase1_enable_rls.sql`
   - `02_kanban_tables.sql`
   - `03_staff_directory.sql`
   - `04_chat_messages.sql`
   - `05_auto_user_role.sql` — auto-creates `user_roles(readonly)` on every signup
   - `06_auto_staff_config.sql` — auto-creates `staff_config(is_active=false)` on every signup
2. Optional: deploy `tasks-auto-archive` Edge Function and schedule it
3. Hard-refresh any portal page and sign in — chat widget appears bottom-left (only on the shell; iframes don't get a duplicate)
4. As an admin, open kanban → 👥 Names → set display names + colors + upload photos for the team. (Or use Time Tracker → Settings — names are editable there too; same RPC, same effect.)
5. Test: open in two browsers as different users → both see chat messages and presence in real time. Quick refreshes should NOT produce join/leave spam thanks to the 25s debounce.

## Where else to look

- `supabase/policies/` — all SQL migrations
- `supabase/functions/tasks-auto-archive/index.ts` — auto-archive Edge Function
- `kanban.html` lines:
  - `~6280` modal HTML for new task
  - `~21500-22000` (block of Sortable.js wiring + drag handlers)
  - `~6700+` JS functions (renderBoard, buildCardEl, etc.)
- `chat-widget.js` is fully self-contained; just one IIFE
- `clinician-map.html` `openKanbanTaskForCurrentClinician()` — the cross-page hook
