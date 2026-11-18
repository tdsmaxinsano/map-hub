// clinician-profile-ai — writes the Territory Planner's 🧠 "Analyst read".
//
// Input:  { clinician_id, facts, facts_hash } — `facts` is the aggregate
//         object built by buildProfileFacts() in territory-planner.html
//         (towns, ZIPs, miles, percentages, counts, dates). It must never
//         contain patient names or street addresses; this function rejects
//         any payload with such keys.
// Output: { narrative, model, generated_at } — also upserted into
//         clinician_ai_profiles (migration 96) with the CALLER's JWT, so
//         RLS (admin/editor write) applies.
//
// Secrets: OPENAI_API_KEY (already set — shared with tb-scan-image) + the
// platform's SUPABASE_URL / SUPABASE_ANON_KEY / SUPABASE_SERVICE_ROLE_KEY.
// Deploy: Supabase dashboard → Edge Functions → clinician-profile-ai
// (keep verify_jwt ON).

import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

// One place to change the model.
const MODEL = "gpt-4o";
const MAX_FACTS_BYTES = 20000;

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS, "Content-Type": "application/json" },
  });
}

// Defense in depth: refuse anything that looks like PHI / row-level data.
const FORBIDDEN_KEY = /patient|address|street|dob|birth|phone|email|mrn/i;
function findForbiddenKey(v: unknown, path = "facts"): string | null {
  if (Array.isArray(v)) {
    for (let i = 0; i < v.length; i++) {
      const hit = findForbiddenKey(v[i], `${path}[${i}]`);
      if (hit) return hit;
    }
  } else if (v && typeof v === "object") {
    for (const [k, val] of Object.entries(v as Record<string, unknown>)) {
      if (FORBIDDEN_KEY.test(k)) return `${path}.${k}`;
      const hit = findForbiddenKey(val, `${path}.${k}`);
      if (hit) return hit;
    }
  }
  return null;
}

const SYSTEM = `You are a staffing analyst at a home-health therapy staffing company in the Chicago area. Schedulers read your notes to decide which referrals to offer a clinician.

You receive a JSON object of pre-computed facts about ONE clinician. Write a short profile from those facts only.

Rules:
- Use only numbers, places, ZIPs and dates that appear in the facts. Never invent, estimate, extrapolate or re-round a number. If you mention a figure, copy it as given.
- If a fact is null, missing, or marked as not enough history, say so briefly or leave it out. Never guess.
- "shift" describes how the clinician's work area changed between an early window and a recent window. Treat it as the most important insight when shift.flag is true; when it is false, say the footprint is stable.
- Plain, direct language. No hype, no praise adjectives, no speculation about personal reasons.

Format (plain text, no markdown headings, no bold):
Line 1: a one-line headline (max ~20 words) naming the clinician.
Then 3 to 5 bullets starting with "• ", covering in this order where facts exist: Tenure & volume · Where they work · Range · Shifts · Fit with TB territory.
Last line: "Scheduling tip: " followed by one actionable sentence grounded in the facts.`;

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });

  try {
    const supabaseUrl = Deno.env.get("SUPABASE_URL") ?? "";
    const anonKey = Deno.env.get("SUPABASE_ANON_KEY") ?? "";
    const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
    const apiKey = Deno.env.get("OPENAI_API_KEY") ?? "";
    if (!supabaseUrl || !serviceKey || !anonKey) return json({ error: "Server missing Supabase config" }, 500);
    if (!apiKey) return json({ error: "Server missing OPENAI_API_KEY secret" }, 500);

    // ── 1. Caller must be a signed-in admin or editor ──
    const authHeader = req.headers.get("Authorization") || "";
    const jwt = authHeader.replace(/^Bearer\s+/i, "");
    const admin = createClient(supabaseUrl, serviceKey);
    const { data: caller, error: authErr } = await admin.auth.getUser(jwt);
    if (authErr || !caller?.user) return json({ error: "Not signed in" }, 401);
    const { data: roleRow } = await admin
      .from("user_roles")
      .select("role")
      .eq("user_id", caller.user.id)
      .maybeSingle();
    if (!roleRow || !["admin", "editor"].includes(roleRow.role)) {
      return json({ error: "Admins and editors only" }, 403);
    }

    // ── 2. Validate the request ──
    const body = await req.json();
    const clinicianId = String(body?.clinician_id || "");
    const factsHash = String(body?.facts_hash || "");
    const facts = body?.facts;
    if (!/^[0-9a-f-]{36}$/i.test(clinicianId)) return json({ error: "clinician_id required" }, 400);
    if (!factsHash) return json({ error: "facts_hash required" }, 400);
    if (!facts || typeof facts !== "object" || Array.isArray(facts)) return json({ error: "facts object required" }, 400);
    const factsJson = JSON.stringify(facts);
    if (factsJson.length > MAX_FACTS_BYTES) return json({ error: "facts too large" }, 413);
    const bad = findForbiddenKey(facts);
    if (bad) return json({ error: `facts must be aggregates only (found ${bad})` }, 400);

    // ── 3. Ask the model ──
    const res = await fetch("https://api.openai.com/v1/chat/completions", {
      method: "POST",
      headers: { "Content-Type": "application/json", "Authorization": `Bearer ${apiKey}` },
      body: JSON.stringify({
        model: MODEL,
        max_tokens: 800,
        temperature: 0.2,
        messages: [
          { role: "system", content: SYSTEM },
          { role: "user", content: "Clinician facts:\n" + factsJson },
        ],
      }),
    });
    const data = await res.json().catch(() => ({}));
    if (!res.ok) {
      const msg = (data && data.error && data.error.message) || res.statusText;
      return json({ error: `AI service error (${res.status}): ${msg}` }, res.status === 429 ? 429 : 502);
    }
    const narrative = String(data?.choices?.[0]?.message?.content || "").trim();
    if (!narrative) return json({ error: "Empty response from the model" }, 502);
    const model = String(data?.model || MODEL);

    // ── 4. Cache it (caller's JWT → RLS applies) ──
    const userDb = createClient(supabaseUrl, anonKey, {
      global: { headers: { Authorization: authHeader } },
    });
    const generatedAt = new Date().toISOString();
    const { error: upErr } = await userDb.from("clinician_ai_profiles").upsert(
      {
        clinician_id: clinicianId,
        facts_hash: factsHash,
        narrative,
        model,
        generated_at: generatedAt,
        generated_by: caller.user.id,
      },
      { onConflict: "clinician_id" },
    );
    if (upErr) console.warn("clinician-profile-ai cache upsert failed:", upErr.message);

    return json({ narrative, model, generated_at: generatedAt, cached: !upErr });
  } catch (err) {
    console.error("clinician-profile-ai error:", err);
    return json({ error: (err as Error).message }, 500);
  }
});
