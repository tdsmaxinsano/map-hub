// Daily-scheduled Edge Function — enforces the Paused/Active state machine.
// =====================================================================
// Single source of truth: status='Paused' ONLY when today falls inside
// [pause_start_date, pause_end_date]. Otherwise → 'Active'. The function
// runs once a day and corrects any drift, writing one audit-log row per
// transition with a typed reason.
//
// Three transitions handled in one pass:
//   A) Paused → Active   when pause_end_date < today
//      reason: "Auto-transition: pause end date passed"
//   B) Paused → Active   when pause_start_date > today (future-scheduled,
//      shouldn't be marked Paused yet)
//      reason: "Auto-transition: pause start date is future"
//   C) Active → Paused   when pause_start_date ≤ today AND
//      (pause_end_date IS NULL OR pause_end_date ≥ today)
//      reason: "Auto-transition: pause start date arrived"
//
// Inactive rows are NEVER touched.
//
// Deploy:
//   supabase functions deploy auto-transition-pauses --project-ref jpemlcuxjvynlbeygukb
// Schedule (Supabase Dashboard → Edge Functions → auto-transition-pauses → Cron):
//   Daily at 11:00 UTC (= 6 AM Chicago CDT, 5 AM CST)
//   Cron expression: 0 11 * * *

import { serve } from "https://deno.land/std@0.224.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

interface ProfileRow {
  clinician_id: string;
  status: string;
  pause_start_date: string | null;
  pause_end_date:   string | null;
}

interface Transition {
  clinician_id: string;
  from_status: string;
  to_status: string;
  reason: string;
}

serve(async (_req) => {
  const supabaseUrl = Deno.env.get("SUPABASE_URL") ?? "";
  const serviceKey  = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
  if (!supabaseUrl || !serviceKey) {
    return jsonResponse({ error: "Missing SUPABASE_URL or SUPABASE_SERVICE_ROLE_KEY env var." }, 500);
  }
  const sb = createClient(supabaseUrl, serviceKey);

  const today = new Date().toISOString().slice(0, 10); // YYYY-MM-DD UTC

  // Pull every non-Inactive row that has at least one pause date set
  // (rows with no dates can't transition; cheap filter).
  const { data: rows, error: selErr } = await sb
    .from("clinician_profiles")
    .select("clinician_id, status, pause_start_date, pause_end_date")
    .neq("status", "Inactive")
    .or("pause_start_date.not.is.null,pause_end_date.not.is.null");

  if (selErr) return jsonResponse({ error: selErr.message }, 500);

  const candidates: ProfileRow[] = (rows ?? []) as ProfileRow[];
  const transitions: Transition[] = [];

  for (const r of candidates) {
    const start = r.pause_start_date;
    const end   = r.pause_end_date;

    // In-window logic
    const startReached = !!start && start <= today;            // pause_start_date ≤ today
    const endNotPassed = !end || end >= today;                 // end is null or ≥ today
    const inWindow     = startReached && endNotPassed;
    const desired      = inWindow ? "Paused" : "Active";
    if (desired === r.status) continue;                        // already correct, skip

    let reason: string;
    if (r.status === "Paused" && !!end && end < today) {
      reason = "Auto-transition: pause end date passed";
    } else if (r.status === "Paused" && !!start && start > today) {
      reason = "Auto-transition: pause start date is future";
    } else if (r.status === "Active" && inWindow) {
      reason = "Auto-transition: pause start date arrived";
    } else {
      // Fall-through: some unusual state (no start but past end, etc.)
      reason = "Auto-transition: status corrected to match dates";
    }

    transitions.push({
      clinician_id: r.clinician_id,
      from_status: r.status,
      to_status: desired,
      reason
    });
  }

  if (transitions.length === 0) {
    return jsonResponse({ transitioned: 0, by_type: {} });
  }

  // Group by desired status so we can UPDATE in two batches max
  const toPaused: string[] = transitions.filter(t => t.to_status === "Paused").map(t => t.clinician_id);
  const toActive: string[] = transitions.filter(t => t.to_status === "Active").map(t => t.clinician_id);
  const nowIso = new Date().toISOString();

  if (toPaused.length) {
    const { error: e1 } = await sb.from("clinician_profiles").update({
      status: "Paused", updated_at: nowIso
    }).in("clinician_id", toPaused);
    if (e1) return jsonResponse({ error: "Paused update (profiles): " + e1.message }, 500);

    const { error: e2 } = await sb.from("clinician_v2").update({
      status: "Paused", active: true   // Paused clinicians remain active=true (off temporarily)
    }).in("id", toPaused);
    if (e2) return jsonResponse({ error: "Paused update (v2): " + e2.message }, 500);
  }

  if (toActive.length) {
    const { error: e3 } = await sb.from("clinician_profiles").update({
      status: "Active", updated_at: nowIso
    }).in("clinician_id", toActive);
    if (e3) return jsonResponse({ error: "Active update (profiles): " + e3.message }, 500);

    const { error: e4 } = await sb.from("clinician_v2").update({
      status: "Active", active: true
    }).in("id", toActive);
    if (e4) return jsonResponse({ error: "Active update (v2): " + e4.message }, 500);
  }

  // Audit log: one row per transition with the typed reason
  const logRows = transitions.map(t => ({
    clinician_id: t.clinician_id,
    from_status: t.from_status,
    to_status: t.to_status,
    reason: t.reason,
    changed_at: nowIso
  }));
  const { error: lErr } = await sb.from("clinician_profile_status_log").insert(logRows);
  if (lErr) return jsonResponse({ error: "status log insert: " + lErr.message }, 500);

  // Roll-up counts by reason type for ops visibility
  const by_type: Record<string, number> = {};
  for (const t of transitions) by_type[t.reason] = (by_type[t.reason] ?? 0) + 1;

  return jsonResponse({ transitioned: transitions.length, by_type });
});

function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" }
  });
}
