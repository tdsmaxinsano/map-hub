// cms-form-watch — detects when Medicare publishes a revised CMS-855I.
//
// Called by enrollment.html on open (JWT-verified, signed-in users only).
// At most once per 6 days it downloads the official CMS PDF, stores a
// SHA-256 of the bytes in cms_form_watch, and flags the row when the
// hash drifts from the acknowledged baseline. All other calls return
// the cached row instantly. A CMS fetch failure records last_error and
// never raises a false alarm.
//
// Deploy: supabase functions deploy cms-form-watch --project-ref jpemlcuxjvynlbeygukb

import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

const FORM_KEY = "cms855i";
const CHECK_INTERVAL_MS = 6 * 24 * 60 * 60 * 1000; // one real CMS hit per 6 days

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS, "Content-Type": "application/json" },
  });
}

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });

  try {
    const db = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
    );

    const { data: row, error } = await db.from("cms_form_watch")
      .select("*").eq("form_key", FORM_KEY).maybeSingle();
    if (error) throw error;
    if (!row) throw new Error("cms_form_watch row missing — run migration 73 first");

    const fresh = row.last_checked_at &&
      (Date.now() - new Date(row.last_checked_at).getTime()) < CHECK_INTERVAL_MS;
    if (fresh) return json(row);

    const patch: Record<string, unknown> = { last_checked_at: new Date().toISOString() };
    try {
      const res = await fetch(row.url, {
        redirect: "follow",
        headers: { "User-Agent": "Mozilla/5.0 (DependableCare portal; CMS form watch)" },
      });
      if (!res.ok) throw new Error("CMS responded HTTP " + res.status);
      const bytes = new Uint8Array(await res.arrayBuffer());
      const digest = await crypto.subtle.digest("SHA-256", bytes);
      const hash = Array.from(new Uint8Array(digest))
        .map((b) => b.toString(16).padStart(2, "0")).join("");

      patch.current_hash = hash;
      patch.current_size = bytes.length;
      patch.current_last_modified = res.headers.get("last-modified");
      patch.last_error = null;

      if (!row.acknowledged_hash) {
        // First run: baseline = today's CMS revision. (Eyeball once that
        // the installed template matches the current official form.)
        patch.acknowledged_hash = hash;
        patch.acknowledged_at = new Date().toISOString();
        patch.changed_detected_at = null;
      } else if (hash !== row.acknowledged_hash) {
        if (!row.changed_detected_at) patch.changed_detected_at = new Date().toISOString();
      } else {
        patch.changed_detected_at = null;
      }
    } catch (fetchErr) {
      patch.last_error = (fetchErr as Error).message;
    }

    const { data: updated, error: upErr } = await db.from("cms_form_watch")
      .update(patch).eq("form_key", FORM_KEY).select().single();
    if (upErr) throw upErr;
    return json(updated);
  } catch (err) {
    console.error("cms-form-watch error:", err);
    return json({ error: (err as Error).message }, 500);
  }
});
