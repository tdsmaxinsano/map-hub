// send-insurance-certificate — email the certificate of insurance to a vendor (SendGrid)
// ====================================================================
// Called from Finance → Renewals → 🛡 Insurance → 📤 Send to a vendor.
// Loads a company_renewal_documents row (migration 97), downloads the
// file from the PRIVATE company-documents bucket, attaches it, emails
// the recipients, and logs the send in company_insurance_sends
// (migration 98).
//
// Admin-only (the documents themselves are admin-only): the bearer JWT
// must belong to a user_roles admin. Every interpolated value is
// HTML-escaped. Reply-To is the sender, so vendor replies reach a person.
//
// Secrets: SENDGRID_API_KEY, SENDGRID_FROM_EMAIL (same as send-user-invite)
// + the platform's SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY defaults.
// Deploy: supabase functions deploy send-insurance-certificate --project-ref jpemlcuxjvynlbeygukb
// (keep default verify_jwt ON).

import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { encode as b64encode } from "https://deno.land/std@0.168.0/encoding/base64.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};
const COMPANY = "Dependable Care Staffing LLC";
const MAX_RECIPIENTS = 10;
const MAX_BYTES = 10 * 1024 * 1024;

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
function mimeFor(name: string): string {
  const ext = (name.split(".").pop() || "").toLowerCase();
  return ({ pdf: "application/pdf", png: "image/png", jpg: "image/jpeg", jpeg: "image/jpeg" } as Record<string, string>)[ext]
    || "application/octet-stream";
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

    // ── 1. Caller must be a signed-in admin ──
    const jwt = (req.headers.get("Authorization") || "").replace(/^Bearer\s+/i, "");
    const { data: caller, error: authErr } = await admin.auth.getUser(jwt);
    if (authErr || !caller?.user) return json({ error: "Not signed in" }, 401);
    const { data: roleRow } = await admin.from("user_roles").select("role")
      .eq("user_id", caller.user.id).maybeSingle();
    if (!roleRow || roleRow.role !== "admin") return json({ error: "Admins only" }, 403);

    // ── 2. Validate ──
    const { documentId, vendorName, recipients, message } = await req.json();
    const vendor = String(vendorName || "").trim().slice(0, 200);
    const list = Array.from(new Set(
      (Array.isArray(recipients) ? recipients : []).map((e: unknown) => String(e || "").trim().toLowerCase()).filter(Boolean),
    ));
    if (!documentId) return json({ error: "Pick a document" }, 400);
    if (!vendor) return json({ error: "Enter the vendor / company name" }, 400);
    if (!list.length) return json({ error: "Enter at least one email" }, 400);
    if (list.length > MAX_RECIPIENTS) return json({ error: `At most ${MAX_RECIPIENTS} recipients` }, 400);
    const bad = list.filter((e) => !/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(e));
    if (bad.length) return json({ error: "Invalid email: " + bad.join(", ") }, 400);
    const note = String(message || "").slice(0, 4000);

    // ── 3. Load the document + file ──
    const { data: doc, error: docErr } = await admin.from("company_renewal_documents").select("*")
      .eq("id", documentId).maybeSingle();
    if (docErr || !doc) return json({ error: "Document not found" }, 404);
    const dl = await admin.storage.from("company-documents").download(doc.document_path);
    if (dl.error || !dl.data) return json({ error: "Couldn't read the file from storage" }, 500);
    const bytes = new Uint8Array(await dl.data.arrayBuffer());
    if (bytes.length > MAX_BYTES) return json({ error: "File is over 10MB — too big to email" }, 400);
    const filename = String(doc.document_name || "certificate-of-insurance.pdf");

    const sender = caller.user.email || "";
    const html = `<!doctype html><html><body style="margin:0;background:#f4f6fa;font-family:Arial,Helvetica,sans-serif;color:#1f2937">
<div style="max-width:640px;margin:0 auto;padding:20px">
  <div style="background:#1E3A5F;color:#fff;border-radius:12px 12px 0 0;padding:16px 20px">
    <div style="font-size:12px;letter-spacing:.6px;text-transform:uppercase;opacity:.8">Certificate of insurance</div>
    <div style="font-size:20px;font-weight:800">${esc(COMPANY)}</div>
  </div>
  <div style="background:#fff;border:1px solid #e2e8f0;border-top:none;border-radius:0 0 12px 12px;padding:18px 20px">
    ${note ? `<p style="margin:0 0 14px;font-size:14px;line-height:1.5;white-space:pre-wrap">${esc(note)}</p>` : ""}
    <p style="margin:0;font-size:13px;color:#475569">📎 Attached: <b>${esc(filename)}</b></p>
    <p style="margin:18px 0 0;font-size:12px;color:#64748b">Sent${sender ? " by " + esc(sender) : ""} on behalf of ${esc(COMPANY)}. Reply to this email with any questions.</p>
  </div>
</div></body></html>`;

    // ── 4. Send ──
    const sg = await fetch("https://api.sendgrid.com/v3/mail/send", {
      method: "POST",
      headers: { Authorization: `Bearer ${sendgridKey}`, "Content-Type": "application/json" },
      body: JSON.stringify({
        personalizations: [{ to: list.map((email) => ({ email })) }],
        from: { email: fromEmail, name: COMPANY },
        reply_to: sender ? { email: sender } : undefined,
        subject: `Certificate of Insurance — ${COMPANY}`,
        content: [{ type: "text/html", value: html }],
        attachments: [{
          content: b64encode(bytes),
          filename,
          type: mimeFor(filename),
          disposition: "attachment",
        }],
      }),
    });
    if (!sg.ok) {
      const detail = await sg.text();
      return json({ error: "SendGrid rejected the email", detail: detail.slice(0, 400) }, 502);
    }

    // ── 5. Log it ──
    const ins = await admin.from("company_insurance_sends").insert({
      document_id: doc.id,
      document_name: filename,
      vendor_name: vendor,
      recipients: list,
      message: note || null,
      method: "email",
      sent_by: caller.user.id,
      sent_by_email: sender || null,
    });
    if (ins.error) return json({ ok: true, sent: list.length, warning: "Sent, but couldn't log it: " + ins.error.message });

    return json({ ok: true, sent: list.length });
  } catch (e) {
    return json({ error: String((e as Error)?.message || e) }, 500);
  }
});
