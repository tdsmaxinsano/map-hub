import { serve } from "https://deno.land/std@0.168.0/http/server.ts";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });

  try {
    const { imageBase64, prompt } = await req.json();
    if (!imageBase64) throw new Error("imageBase64 required");

    const apiKey = Deno.env.get("OPENAI_API_KEY")!;
    const defaultPrompt = "This is a screenshot of a TherapyBoss referral list. Extract all referrals as a JSON array. Each object should have these fields:\n- patient_name (string, 'Last, First Middle' format)\n- address (string, full street address with city, state, zip)\n- disciplines (array of strings, e.g. [\"PT\"], [\"OT\"], [\"PT\",\"OT\"] — if the same patient appears on multiple rows for different disciplines, merge them into one record with all disciplines)\n- agency (string, the home health agency name)\n- referral_date (string, YYYY-MM-DD, from the date/time column)\n- insurance (string, e.g. 'Medicare Home Health')\n\nReturn ONLY a valid JSON array. No markdown fences, no explanation.";

    const res = await fetch("https://api.openai.com/v1/chat/completions", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "Authorization": `Bearer ${apiKey}`
      },
      body: JSON.stringify({
        model: "gpt-4o",
        max_tokens: 4096,
        messages: [{
          role: "user",
          content: [
            { type: "text",      text: prompt || defaultPrompt },
            { type: "image_url", image_url: { url: imageBase64, detail: "high" } }
          ]
        }]
      })
    });

    const data = await res.json();
    if (!res.ok) throw new Error((data.error && data.error.message) || res.statusText);

    return new Response(JSON.stringify(data), {
      headers: { ...CORS, "Content-Type": "application/json" }
    });

  } catch (err) {
    console.error("tb-scan-image error:", err);
    return new Response(JSON.stringify({ error: (err as Error).message }), {
      status: 500,
      headers: { ...CORS, "Content-Type": "application/json" }
    });
  }
});
