// tasks-auto-archive
// Scheduled Edge Function. Flips `is_archived = true` on tasks that completed
// 7+ days ago, so the Done column doesn't bloat over time.
// Schedule via Supabase: daily, e.g. 03:00 UTC.

import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });

  try {
    // Service role key is required to bypass RLS for the bulk update.
    const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
    const SERVICE_KEY  = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
    if (!SUPABASE_URL || !SERVICE_KEY) {
      throw new Error("Missing SUPABASE_URL or SUPABASE_SERVICE_ROLE_KEY");
    }
    const admin = createClient(SUPABASE_URL, SERVICE_KEY);

    const cutoff = new Date();
    cutoff.setDate(cutoff.getDate() - 7);
    const cutoffIso = cutoff.toISOString();

    const { data, error, count } = await admin
      .from("tasks")
      .update({ is_archived: true, archived_at: new Date().toISOString() })
      .eq("is_archived", false)
      .not("completed_at", "is", null)
      .lt("completed_at", cutoffIso)
      .select("id", { count: "exact" });

    if (error) throw error;

    return new Response(
      JSON.stringify({ ok: true, archived: count ?? 0, ids: (data || []).map((r: any) => r.id) }),
      { headers: { ...CORS, "Content-Type": "application/json" } }
    );
  } catch (err) {
    console.error("tasks-auto-archive error:", err);
    return new Response(
      JSON.stringify({ ok: false, error: (err as Error).message }),
      { status: 500, headers: { ...CORS, "Content-Type": "application/json" } }
    );
  }
});
