// Daily-scheduled Edge Function — flips stale Paused → Active.
// =====================================================================
// Runs once a day via Supabase Edge Function cron. Finds every clinician
// whose status = 'Paused' AND pause_end_date < today, updates them to
// status = 'Active' in BOTH clinician_profiles AND clinician_v2, and
// appends an audit-log row to clinician_profile_status_log with reason
// "Auto-transition: pause end date passed".
//
// Why both tables: clinician_v2 is the canonical reference for the map's
// markers + roster filters; clinician_profiles is the editor-side
// authoritative state. The existing manual save path (the Roster Review
// status dropdown) writes to BOTH — this Edge Function does the same so
// auto-transitions are indistinguishable from manual flips downstream.
//
// Deploy:
//   supabase functions deploy auto-transition-pauses --project-ref jpemlcuxjvynlbeygukb
// Schedule (Supabase Dashboard → Edge Functions → auto-transition-pauses → Cron):
//   Daily at 11:00 UTC (= 6 AM Chicago in CDT, 5 AM in CST)
//   Cron expression: 0 11 * * *

import { serve } from "https://deno.land/std@0.224.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

interface StaleRow { clinician_id: string }

serve(async (_req) => {
  const supabaseUrl = Deno.env.get("SUPABASE_URL") ?? "";
  const serviceKey  = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
  if (!supabaseUrl || !serviceKey) {
    return jsonResponse({ error: "Missing SUPABASE_URL or SUPABASE_SERVICE_ROLE_KEY env var." }, 500);
  }
  const sb = createClient(supabaseUrl, serviceKey);

  const today = new Date().toISOString().slice(0, 10); // YYYY-MM-DD UTC

  // 1. Find clinicians whose pause has ended
  const { data: stale, error: selErr } = await sb
    .from("clinician_profiles")
    .select("clinician_id")
    .eq("status", "Paused")
    .lt("pause_end_date", today);

  if (selErr) return jsonResponse({ error: selErr.message }, 500);

  const ids: string[] = (stale as StaleRow[] | null)?.map(r => r.clinician_id) ?? [];
  if (ids.length === 0) {
    return jsonResponse({ transitioned: 0, ids: [] });
  }

  const nowIso = new Date().toISOString();

  // 2. Update clinician_profiles
  const { error: pErr } = await sb
    .from("clinician_profiles")
    .update({ status: "Active", updated_at: nowIso })
    .in("clinician_id", ids);
  if (pErr) return jsonResponse({ error: "clinician_profiles update: " + pErr.message }, 500);

  // 3. Update clinician_v2 (status + active flag)
  const { error: vErr } = await sb
    .from("clinician_v2")
    .update({ status: "Active", active: true })
    .in("id", ids);
  if (vErr) return jsonResponse({ error: "clinician_v2 update: " + vErr.message }, 500);

  // 4. Audit log: one row per transition, same shape the map's
  //    saveClinicianStatusHistoryToSupabase uses
  const logRows = ids.map(clinician_id => ({
    clinician_id,
    from_status: "Paused",
    to_status: "Active",
    reason: "Auto-transition: pause end date passed",
    changed_at: nowIso
  }));
  const { error: lErr } = await sb.from("clinician_profile_status_log").insert(logRows);
  if (lErr) return jsonResponse({ error: "status log insert: " + lErr.message }, 500);

  return jsonResponse({ transitioned: ids.length, ids });
});

function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" }
  });
}
