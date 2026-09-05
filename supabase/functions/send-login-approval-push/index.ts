import * as jose from "https://esm.sh/jose@5";

// Feature: new-login accept/deny flow (opt-in, default OFF). Reuses the
// exact same free-tier pattern send-push already uses (this Edge
// Function, a Database Webhook, and the FCM HTTP v1 API) — see that
// function's own file for the fuller explanation of why. This one fires
// off inserts into `login_approval_requests` (see
// supabase/migrations/0002_login_approval_requests.sql) instead of
// `message_relay`, and pushes a "new login — accept or deny" notification
// instead of a "you have a new message" one.

const FIREBASE_PROJECT_ID = Deno.env.get("FIREBASE_PROJECT_ID")!;
const SERVICE_ACCOUNT_EMAIL = Deno.env.get("FIREBASE_SERVICE_ACCOUNT_EMAIL")!;
const SERVICE_ACCOUNT_PRIVATE_KEY = Deno.env.get("FIREBASE_SERVICE_ACCOUNT_PRIVATE_KEY")!.replace(/\\n/g, "\n");
const WEBHOOK_SECRET = Deno.env.get("PUSH_WEBHOOK_SECRET")!;

const TOKEN_URL = "https://oauth2.googleapis.com/token";
const FIRESTORE_BASE = `https://firestore.googleapis.com/v1/projects/${FIREBASE_PROJECT_ID}/databases/(default)/documents`;

let cachedToken: { token: string; expiresAt: number } | null = null;

async function getAccessToken(): Promise<string> {
  if (cachedToken && cachedToken.expiresAt > Date.now() + 30_000) {
    return cachedToken.token;
  }
  const privateKey = await jose.importPKCS8(SERVICE_ACCOUNT_PRIVATE_KEY, "RS256");
  const now = Math.floor(Date.now() / 1000);
  const assertion = await new jose.SignJWT({
    scope: "https://www.googleapis.com/auth/datastore https://www.googleapis.com/auth/firebase.messaging",
  })
    .setProtectedHeader({ alg: "RS256" })
    .setIssuer(SERVICE_ACCOUNT_EMAIL)
    .setSubject(SERVICE_ACCOUNT_EMAIL)
    .setAudience(TOKEN_URL)
    .setIssuedAt(now)
    .setExpirationTime(now + 3600)
    .sign(privateKey);

  const res = await fetch(TOKEN_URL, {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer",
      assertion,
    }),
  });
  if (!res.ok) throw new Error(`Google token exchange failed: ${await res.text()}`);
  const data = await res.json();
  cachedToken = { token: data.access_token, expiresAt: Date.now() + data.expires_in * 1000 };
  return data.access_token;
}

function fsValue(v: any): any {
  if (v == null) return null;
  if ("stringValue" in v) return v.stringValue;
  if ("booleanValue" in v) return v.booleanValue;
  if ("integerValue" in v) return Number(v.integerValue);
  if ("arrayValue" in v) return (v.arrayValue.values ?? []).map(fsValue);
  if ("mapValue" in v) return fsFields(v.mapValue.fields ?? {});
  return null;
}
function fsFields(fields: Record<string, any>): Record<string, any> {
  const out: Record<string, any> = {};
  for (const k in fields) out[k] = fsValue(fields[k]);
  return out;
}

async function getDoc(path: string, accessToken: string): Promise<Record<string, any> | null> {
  const res = await fetch(`${FIRESTORE_BASE}/${path}`, {
    headers: { Authorization: `Bearer ${accessToken}` },
  });
  if (res.status === 404) return null;
  if (!res.ok) throw new Error(`Firestore read failed (${path}): ${await res.text()}`);
  const data = await res.json();
  return fsFields(data.fields ?? {});
}

Deno.serve(async (req) => {
  try {
    if (req.headers.get("X-Webhook-Secret") !== WEBHOOK_SECRET) {
      return new Response("Forbidden", { status: 403 });
    }

    const { record } = await req.json();
    if (!record?.uid || !record?.request_id) {
      return new Response("Skipped", { status: 200 });
    }

    const accessToken = await getAccessToken();
    const recipientProfile = await getDoc(`users/${record.uid}/private/profile`, accessToken);
    const tokens: string[] = recipientProfile?.fcmTokens ?? [];
    if (tokens.length === 0) return new Response("No tokens", { status: 200 });

    const deviceLabel = String(record.device_label ?? "A device");
    const location = record.location ? String(record.location) : null;
    const bodyText = location ? `${deviceLabel} • ${location} wants to sign in` : `${deviceLabel} wants to sign in`;

    const results = await Promise.all(
      tokens.map(async (token) => {
        const res = await fetch(`https://fcm.googleapis.com/v1/projects/${FIREBASE_PROJECT_ID}/messages:send`, {
          method: "POST",
          headers: { Authorization: `Bearer ${accessToken}`, "Content-Type": "application/json" },
          body: JSON.stringify({
            message: {
              token,
              notification: { title: "New login request", body: bodyText },
              data: {
                type: "login_approval",
                requestId: String(record.request_id),
                deviceLabel,
                location: location ?? "",
              },
              android: { priority: "high" },
              apns: { headers: { "apns-priority": "10" } },
            },
          }),
        });
        return res.ok;
      }),
    );

    return new Response(JSON.stringify({ sent: results.filter(Boolean).length, total: tokens.length }), { status: 200 });
  } catch (err) {
    return new Response(JSON.stringify({ error: String(err) }), { status: 500 });
  }
});
