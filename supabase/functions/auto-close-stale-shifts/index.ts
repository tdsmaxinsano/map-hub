// Hourly-scheduled Edge Function — auto-close forgotten clock-outs.
// =====================================================================
// The portal enforces a 10-hour daily shift cap (MAX_SHIFT_HOURS), but the
// auto-clock-out is a CLIENT-SIDE timer that only runs while the staff's
// browser tab is open (startHardStopMonitor in time-tracker.html). If a staff
// member clocks in and then closes the tab — or the laptop sleeps / loses
// internet — nothing closes the shift. It stays open for hours/days and, once
// finally closed, lands a 24h/96h "single day" that inflates payroll totals.
//
// This sweep finds every OPEN shift (clock_out IS NULL) whose clock_in is older
// than 10 hours and closes it AT clock_in + 10h — the same cap the client
// applies to hour totals — tagging manual_note with "AutoClosed|..." so the
// portal can mark it "auto-closed — verify" (tell it apart from a real 10h day)
// and the admin can correct the true clock-out via the Shifts modal.
//
// Idempotent: once clock_out is set the shift is no longer selected.
// Safe: only ever touches OPEN shifts older than the cap; never edits a shift
// that already has a real clock_out, and the per-row UPDATE re-guards
// clock_out IS NULL to avoid clobbering a shift the staff closes mid-run.
//
// The final clock_out is always clock_in + 10h regardless of when the sweep
// runs, so the cadence only affects how quickly the DB / live UI reflects the
// closure — hourly keeps a "still running 30h" row from lingering for a day.
//
// Deploy:
//   supabase functions deploy auto-close-stale-shifts --project-ref jpemlcuxjvynlbeygukb
// Schedule (Supabase Dashboard → Edge Functions → auto-close-stale-shifts → Cron):
//   Hourly, top of the hour
//   Cron expression: 0 * * * *

import { serve } from "https://deno.land/std@0.224.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const MAX_SHIFT_HOURS = 10;
const CAP_MS = MAX_SHIFT_HOURS * 60 * 60 * 1000;

interface ShiftRow {
  id: string;
  user_id: string;
  clock_in: string;
  manual_note: string | null;
}

serve(async (_req) => {
  const supabaseUrl = Deno.env.get("SUPABASE_URL") ?? "";
  const serviceKey  = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
  if (!supabaseUrl || !serviceKey) {
    return jsonResponse({ error: "Missing SUPABASE_URL or SUPABASE_SERVICE_ROLE_KEY env var." }, 500);
  }
  const sb = createClient(supabaseUrl, serviceKey);

  // Open shifts whose clock_in is older than the cap are forgotten clock-outs.
  const cutoffIso = new Date(Date.now() - CAP_MS).toISOString();
  const { data: rows, error: selErr } = await sb
    .from("time_entries")
    .select("id, user_id, clock_in, manual_note")
    .is("clock_out", null)
    .lte("clock_in", cutoffIso);

  if (selErr) return jsonResponse({ error: selErr.message }, 500);

  const stale: ShiftRow[] = (rows ?? []) as ShiftRow[];
  if (stale.length === 0) return jsonResponse({ scanned: 0, closed: 0 });

  let closed = 0;
  const errors: { id: string; error: string }[] = [];

  for (const r of stale) {
    const closeAtIso = new Date(new Date(r.clock_in).getTime() + CAP_MS).toISOString();
    // Tag so the portal can mark it "auto-closed — verify". Preserve any prior
    // note; never double-prefix on a re-run.
    const prior = r.manual_note && !r.manual_note.startsWith("AutoClosed|") ? " " + r.manual_note : "";
    const note  = `AutoClosed|forgotten clock-out (${MAX_SHIFT_HOURS}h cap)${prior}`;

    const { error: updErr } = await sb
      .from("time_entries")
      .update({ clock_out: closeAtIso, manual_note: note })
      .eq("id", r.id)
      .is("clock_out", null); // re-guard against a race: skip if just closed

    if (updErr) errors.push({ id: r.id, error: updErr.message });
    else closed++;
  }

  return jsonResponse({ scanned: stale.length, closed, errors });
});

function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" }
  });
}
