// send-coverage-report — email a stored coverage change report (SendGrid)
// ====================================================================
// Called from the Territory Planner's 📸 Coverage change report modal.
// Optional and manual: nothing calls this automatically. Loads a
// coverage_change_reports row (migration 94), attaches its marked-up
// map PNG inline (cid:coverage-map) from the private coverage-reports
// bucket, emails the before/after lists, and records sent_at / sent_to.
//
// Verifies the caller: the bearer JWT must belong to an admin or editor
// (verify_jwt alone only proves "some signed-in user"). Every
// interpolated value is HTML-escaped. No patient data is involved —
// only ZIP codes, the clinician's name, and the change reason/note.
//
// Secrets: SENDGRID_API_KEY, SENDGRID_FROM_EMAIL (same as send-user-invite)
// + the platform's SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY defaults.
// Deploy: supabase functions deploy send-coverage-report --project-ref jpemlcuxjvynlbeygukb
// (keep default verify_jwt ON).

import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { encode as b64encode } from "https://deno.land/std@0.168.0/encoding/base64.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};
const PORTAL_URL = "https://www.dependablecareportal.com/";
const MAX_RECIPIENTS = 20;

function esc(s: unknown): string {
  return String(s ?? "").replace(/[&<>"']/g, (c) =>
    ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]!)
  );
}
function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS, "Content-Type": "application/json" },
  });
}
function zipList(zips: string[], color: string, prefix: string): string {
  if (!zips.length) return `<span style="color:#94a3b8">none</span>`;
  return zips.map((z) =>
    `<span style="display:inline-block;margin:2px 3px;padding:2px 8px;border-radius:999px;font-weight:700;font-size:12px;border:1px solid ${color};color:${color}">${esc(prefix)}${esc(z)}</span>`
  ).join("");
}

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });

  try {
    const supabaseUrl = Deno.env.get("SUPABASE_URL") ?? "";
    const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
    const sendgridKey = Deno.env.get("SENDGRID_API_KEY") ?? "";
    const fromEmail = Deno.env.get("SENDGRID_FROM_EMAIL") ?? "";
    if (!supabaseUrl || !serviceKey) return json({ error: "Server missing Supabase config" }, 500);
    if (!sendgridKey || !fromEmail) return json({ error: "Server missing SendGrid config" }, 500);

    const admin = createClient(supabaseUrl, serviceKey);

    // ── 1. Caller must be a signed-in admin or editor ──
    const jwt = (req.headers.get("Authorization") || "").replace(/^Bearer\s+/i, "");
    const { data: caller, error: authErr } = await admin.auth.getUser(jwt);
    if (authErr || !caller?.user) return json({ error: "Not signed in" }, 401);
    const { data: roleRow } = await admin.from("user_roles").select("role")
      .eq("user_id", caller.user.id).maybeSingle();
    if (!roleRow || !["admin", "editor"].includes(roleRow.role)) return json({ error: "Admins and editors only" }, 403);

    // ── 2. Validate ──
    const { reportId, recipients, message } = await req.json();
    const list = Array.from(new Set(
      (Array.isArray(recipients) ? recipients : []).map((e: unknown) => String(e || "").trim().toLowerCase()).filter(Boolean),
    ));
    if (!reportId) return json({ error: "Missing reportId" }, 400);
    if (!list.length) return json({ error: "Pick at least one recipient" }, 400);
    if (list.length > MAX_RECIPIENTS) return json({ error: `At most ${MAX_RECIPIENTS} recipients` }, 400);
    const bad = list.filter((e) => !/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(e));
    if (bad.length) return json({ error: "Invalid email: " + bad.join(", ") }, 400);

    // ── 3. Load the report + clinician + image ──
    const { data: rep, error: repErr } = await admin.from("coverage_change_reports").select("*")
      .eq("id", reportId).maybeSingle();
    if (repErr || !rep) return json({ error: "Report not found" }, 404);
    const { data: clin } = await admin.from("clinician_v2").select("name").eq("id", rep.clinician_id).maybeSingle();
    const clinName = (clin && clin.name) || "Clinician";

    let attachments: unknown[] = [];
    let hasImage = false;
    if (rep.image_path) {
      const dl = await admin.storage.from("coverage-reports").download(rep.image_path);
      if (!dl.error && dl.data) {
        const bytes = new Uint8Array(await dl.data.arrayBuffer());
        attachments = [{
          content: b64encode(bytes),
          filename: "coverage-change.png",
          type: "image/png",
          disposition: "inline",
          content_id: "coverage-map",
        }];
        hasImage = true;
      }
    }

    const before: string[] = rep.zips_before || [];
    const after: string[] = rep.zips_after || [];
    const added: string[] = rep.added || [];
    const removed: string[] = rep.removed || [];
    const unchanged = after.filter((z) => !added.includes(z));
    const when = new Date(rep.created_at).toLocaleDateString("en-US", { month: "short", day: "numeric", year: "numeric" });
    const sender = caller.user.email || "DependableCare";

    const html = `<!doctype html><html><body style="margin:0;background:#f4f6fa;font-family:Arial,Helvetica,sans-serif;color:#1f2937">
<div style="max-width:720px;margin:0 auto;padding:20px">
  <div style="background:#1E3A5F;color:#fff;border-radius:12px 12px 0 0;padding:16px 20px">
    <div style="font-size:12px;letter-spacing:.6px;text-transform:uppercase;opacity:.8">Coverage change</div>
    <div style="font-size:20px;font-weight:800">${esc(clinName)}</div>
    <div style="font-size:13px;opacity:.9">${esc(when)}${rep.reason ? " · " + esc(rep.reason) : ""} · Before ${before.length} → After ${after.length} · +${added.length} / −${removed.length}</div>
  </div>
  <div style="background:#fff;border:1px solid #e2e8f0;border-top:none;border-radius:0 0 12px 12px;padding:18px 20px">
    ${message ? `<p style="margin:0 0 14px;font-size:14px;line-height:1.5;white-space:pre-wrap">${esc(message)}</p>` : ""}
    ${rep.note ? `<p style="margin:0 0 14px;font-size:13px;color:#475569"><b>Note:</b> ${esc(rep.note)}</p>` : ""}
    ${hasImage ? `<img src="cid:coverage-map" alt="Coverage change map" style="width:100%;max-width:680px;border:1px solid #e2e8f0;border-radius:8px;display:block;margin:0 0 16px">` : ""}
    <table cellpadding="0" cellspacing="0" style="width:100%;font-size:13px;border-collapse:collapse">
      <tr><td style="padding:6px 0;width:120px;font-weight:800;color:#166534;vertical-align:top">Added (${added.length})</td><td style="padding:6px 0">${zipList(added, "#166534", "+ ")}</td></tr>
      <tr><td style="padding:6px 0;font-weight:800;color:#b3261e;vertical-align:top">Removed (${removed.length})</td><td style="padding:6px 0">${zipList(removed, "#b3261e", "− ")}</td></tr>
      <tr><td style="padding:6px 0;font-weight:800;color:#1a5fb4;vertical-align:top">Unchanged (${unchanged.length})</td><td style="padding:6px 0">${zipList(unchanged, "#1a5fb4", "")}</td></tr>
      <tr><td style="padding:10px 0 4px;font-weight:800;color:#475569;vertical-align:top">Before (${before.length})</td><td style="padding:10px 0 4px;color:#475569">${esc(before.join(", ") || "—")}</td></tr>
      <tr><td style="padding:4px 0;font-weight:800;color:#475569;vertical-align:top">After (${after.length})</td><td style="padding:4px 0;color:#475569">${esc(after.join(", ") || "—")}</td></tr>
    </table>
    <p style="margin:18px 0 0;font-size:12px;color:#64748b">Sent by ${esc(sender)} from the DependableCare portal · <a href="${PORTAL_URL}" style="color:#1a5fb4">Open portal</a></p>
  </div>
</div></body></html>`;

    // ── 4. Send ──
    const sg = await fetch("https://api.sendgrid.com/v3/mail/send", {
      method: "POST",
      headers: { Authorization: `Bearer ${sendgridKey}`, "Content-Type": "application/json" },
      body: JSON.stringify({
        personalizations: [{ to: list.map((email) => ({ email })) }],
        from: { email: fromEmail, name: "DependableCare Portal" },
        reply_to: caller.user.email ? { email: caller.user.email } : undefined,
        subject: `Coverage change — ${clinName} (+${added.length} / −${removed.length})`,
        content: [{ type: "text/html", value: html }],
        attachments: attachments.length ? attachments : undefined,
      }),
    });
    if (!sg.ok) {
      const detail = await sg.text();
      return json({ error: "SendGrid rejected the email", detail: detail.slice(0, 400) }, 502);
    }

    // ── 5. Record it ──
    const prevTo: string[] = rep.sent_to || [];
    await admin.from("coverage_change_reports").update({
      sent_at: new Date().toISOString(),
      sent_to: Array.from(new Set(prevTo.concat(list))),
      sent_by_email: caller.user.email || null,
    }).eq("id", reportId);

    return json({ ok: true, sent: list.length });
  } catch (e) {
    return json({ error: String((e as Error)?.message || e) }, 500);
  }
});
