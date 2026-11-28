import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { Webhook } from "npm:standardwebhooks@1.0.0";

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json", "Cache-Control": "no-store" },
  });

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);

  const hookSecret = Deno.env.get("SEND_SMS_HOOK_SECRET");
  const accessToken = Deno.env.get("META_WA_ACCESS_TOKEN");
  const phoneNumberId = Deno.env.get("META_WA_PHONE_NUMBER_ID");
  const templateName = Deno.env.get("META_WA_OTP_TEMPLATE");
  const templateLanguage = Deno.env.get("META_WA_OTP_LANGUAGE") || "en_US";
  const graphVersion = Deno.env.get("META_GRAPH_API_VERSION");

  if (!hookSecret || !accessToken || !phoneNumberId || !templateName || !graphVersion) {
    console.error("WhatsApp OTP configuration is incomplete.");
    return json({ error: "WhatsApp OTP is not configured yet." }, 503);
  }

  const rawBody = await req.text();
  let event: { user?: { phone?: string }; sms?: { otp?: string } };

  try {
    const headers = Object.fromEntries(req.headers.entries());
    event = new Webhook(hookSecret).verify(rawBody, headers) as typeof event;
  } catch (_error) {
    return json({ error: "Invalid Auth Hook signature." }, 401);
  }

  const phone = String(event.user?.phone || "");
  const otp = String(event.sms?.otp || "");
  if (!/^\+[1-9]\d{7,14}$/.test(phone) || !/^\d{4,8}$/.test(otp)) {
    return json({ error: "Invalid phone number or OTP payload." }, 400);
  }

  const to = phone.replace(/^\+/, "");
  const payload = {
    messaging_product: "whatsapp",
    recipient_type: "individual",
    to,
    type: "template",
    template: {
      name: templateName,
      language: { code: templateLanguage },
      components: [
        { type: "body", parameters: [{ type: "text", text: otp }] },
        {
          type: "button",
          sub_type: "url",
          index: "0",
          parameters: [{ type: "text", text: otp }],
        },
      ],
    },
  };

  try {
    const response = await fetch(
      `https://graph.facebook.com/${graphVersion}/${phoneNumberId}/messages`,
      {
        method: "POST",
        headers: {
          Authorization: `Bearer ${accessToken}`,
          "Content-Type": "application/json",
        },
        body: JSON.stringify(payload),
      },
    );
    const result = await response.json().catch(() => ({}));
    if (!response.ok) {
      console.error("Meta WhatsApp API rejected OTP delivery:", JSON.stringify({
        status: response.status,
        error: result?.error?.code || "unknown",
        subcode: result?.error?.error_subcode || null,
      }));
      return json({ error: "WhatsApp OTP delivery failed. Please try again." }, 502);
    }
    return new Response(null, { status: 200 });
  } catch (error) {
    console.error("WhatsApp OTP request failed:", error instanceof Error ? error.message : "unknown");
    return json({ error: "WhatsApp OTP service is temporarily unavailable." }, 502);
  }
});
