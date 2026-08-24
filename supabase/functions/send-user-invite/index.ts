// send-user-invite — admin sends a portal invite email (SendGrid)
// ====================================================================
// Called from the Map's 👥 Users modal. Records/updates the invite in
// public.user_invites, then emails the invitee a link to the portal
// with instructions to create their account using THIS email address —
// the rebuilt handle_new_user() trigger (migration 64) assigns the
// invited role automatically at signup. Uninvited signups become
// role='pending' instead.
//
// Unlike the older send-* functions, this one VERIFIES THE CALLER:
// the bearer JWT must belong to a user whose user_roles.role = 'admin'
// (verify_jwt alone only proves "some signed-in user"). It also
// HTML-escapes every interpolated value.
//
// Secrets: SENDGRID_API_KEY, SENDGRID_FROM_EMAIL (+ the platform's
// SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY defaults).
// Deploy: supabase functions deploy send-user-invite --project-ref jpemlcuxjvynlbeygukb
// (keep default verify_jwt ON).

import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

const PORTAL_URL = "https://www.dependablecareportal.com/";

const ROLE_LABELS: Record<string, string> = {
  admin: "Administrator",
  editor: "Editor",
  readonly: "View Only",
  clinician: "Clinician (your own territory)",
};

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

    // ── 1. Verify the caller is a signed-in ADMIN ──
    const jwt = (req.headers.get("Authorization") || "").replace(/^Bearer\s+/i, "");
    const { data: caller, error: authErr } = await admin.auth.getUser(jwt);
    if (authErr || !caller?.user) return json({ error: "Not signed in" }, 401);
    const { data: roleRow } = await admin
      .from("user_roles")
      .select("role")
      .eq("user_id", caller.user.id)
      .maybeSingle();
    if (!roleRow || roleRow.role !== "admin") return json({ error: "Admin only" }, 403);

    // ── 2. Validate the request ──
    const { email, role, clinicianId, clinicianName } = await req.json();
    const emailNorm = String(email || "").trim().toLowerCase();
    if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(emailNorm)) return json({ error: "Invalid email address" }, 400);
    if (!["admin", "editor", "readonly", "clinician"].includes(role)) return json({ error: "Invalid role" }, 400);
    if (role === "clinician" && !clinicianId) {
      return json({ error: "Clinician invites need a linked clinician record" }, 400);
    }

    // ── 3. Refuse if the email already has an account ──
    const { data: existing } = await admin
      .from("user_roles")
      .select("user_id")
      .ilike("email", emailNorm)
      .maybeSingle();
    if (existing) {
      return json({ error: "That email already has an account — change their role in the user list instead." }, 409);
    }

    // ── 4. Upsert the invite (resend + re-invite-after-revoke revive the row) ──
    const { error: invErr } = await admin.from("user_invites").upsert(
      {
        email: emailNorm,
        role,
        clinician_id: clinicianId || null,
        invited_by_email: caller.user.email || null,
        invited_at: new Date().toISOString(),
        accepted_at: null,
        accepted_user_id: null,
        revoked_at: null,
      },
      { onConflict: "email_norm" },
    );
    if (invErr) throw invErr;

    // ── 5. Send the invite email ──
    const roleLabel = ROLE_LABELS[role] || role;
    const inviterName = (caller.user.email || "an administrator").split("@")[0];
    const html = `
      <div style="font-family:Arial,Helvetica,sans-serif;max-width:560px;margin:0 auto;color:#1e2d4a;">
        <h2 style="color:#1E3A5F;">You're invited to the DependableCare Portal</h2>
        <p><b>${esc(inviterName)}</b> has invited you to join the DependableCare Portal
           as <b>${esc(roleLabel)}</b>${clinicianName ? ` (linked to ${esc(clinicianName)})` : ""}.</p>
        <ol style="line-height:1.7;">
          <li>Go to <a href="${PORTAL_URL}" style="color:#2463eb;">${PORTAL_URL}</a></li>
          <li>Click <b>Create account</b></li>
          <li>Sign up using <b>this email address</b> (${esc(emailNorm)}) and a password of your choice</li>
        </ol>
        <p>Your access is set up automatically the moment you sign up — no further steps.</p>
        <p style="color:#6b7280;font-size:12px;">If you weren't expecting this invitation, you can ignore this email.</p>
        <hr style="border:none;border-top:1px solid #e5e7eb;margin:18px 0;">
        <p style="color:#9ca3af;font-size:11px;">Sent from DependableCare Portal</p>
      </div>`;

    const res = await fetch("https://api.sendgrid.com/v3/mail/send", {
      method: "POST",
      headers: {
        Authorization: `Bearer ${sendgridKey}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        personalizations: [{ to: [{ email: emailNorm }] }],
        from: { email: fromEmail, name: "DependableCare Portal" },
        subject: "You're invited to the DependableCare Portal",
        content: [{ type: "text/html", value: html }],
      }),
    });
    if (!res.ok) {
      throw new Error(`SendGrid ${res.status}: ${await res.text()}`);
    }

    return json({ ok: true });
  } catch (err) {
    console.error("send-user-invite error:", err);
    return json({ error: (err as Error).message }, 500);
  }
});
