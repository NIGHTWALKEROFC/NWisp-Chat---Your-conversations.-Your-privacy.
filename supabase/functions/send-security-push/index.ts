import * as jose from "https://esm.sh/jose@5";

// Feature: "NWisp Chat" security notices. When something sensitive happens on
// an account (a new sign-in, a password change, two-step verification turned
// on or off) the app calls this function, and every phone signed in to that
// account gets a push notification titled "NWisp Chat". Tapping it opens the
// in-app NWisp Chat security conversation.
//
// Same free-tier pieces send-push already uses: this Edge Function, and the
// FCM HTTP v1 API. No Firebase Cloud Functions, no Blaze plan.
//
// Authenticated with the caller's Firebase ID token (same check the totp-*
// functions do). The account notified is ALWAYS the one the token belongs to,
// never one named in the request body — so nobody can use this to push
// fake "security alerts" to somebody else's phone.
//
// SINGLE-FILE VERSION on purpose (no imports from ../_shared) so it can be
// pasted straight into the Supabase dashboard editor.
//
// Secrets it reads (all already set for send-push):
//   FIREBASE_PROJECT_ID, FIREBASE_SERVICE_ACCOUNT_EMAIL,
//   FIREBASE_SERVICE_ACCOUNT_PRIVATE_KEY

const FIREBASE_PROJECT_ID = Deno.env.get("FIREBASE_PROJECT_ID")!;
const SERVICE_ACCOUNT_EMAIL = Deno.env.get("FIREBASE_SERVICE_ACCOUNT_EMAIL")!;
const SERVICE_ACCOUNT_PRIVATE_KEY = Deno.env.get("FIREBASE_SERVICE_ACCOUNT_PRIVATE_KEY")!.replace(/\\n/g, "\n");

const TOKEN_URL = "https://oauth2.googleapis.com/token";
const FIRESTORE_BASE = `https://firestore.googleapis.com/v1/projects/${FIREBASE_PROJECT_ID}/databases/(default)/documents`;
const JWKS = jose.createRemoteJWKSet(
  new URL("https://www.googleapis.com/service_accounts/v1/jwk/securetoken@system.gserviceaccount.com"),
);

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, content-type",
};

// What each event says on the lock screen. Kept short and free of IP
// addresses on purpose — anyone holding the phone can read a notification.
const EVENT_TEXT: Record<string, (device: string) => string> = {
  login: (d) => `New sign-in on ${d}. If this wasn't you, change your password now.`,
  password_changed: (d) => `Your password was changed from ${d}. If this wasn't you, act now.`,
  totp_enabled: () => "Two-step verification was turned on for your account.",
  totp_disabled: () => "Two-step verification was turned OFF for your account. If this wasn't you, act now.",
};

let cachedToken: { token: string; expiresAt: number } | null = null;

async function getAccessToken(): Promise<string> {
  if (cachedToken && cachedToken.expiresAt > Date.now() + 30_000) return cachedToken.token;
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
    body: new URLSearchParams({ grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer", assertion }),
  });
  if (!res.ok) throw new Error(`Google token exchange failed: ${await res.text()}`);
  const data = await res.json();
  cachedToken = { token: data.access_token, expiresAt: Date.now() + data.expires_in * 1000 };
  return data.access_token;
}

async function verifyIdToken(req: Request): Promise<string> {
  const idToken = (req.headers.get("Authorization") || "").replace("Bearer ", "");
  if (!idToken) throw new Error("Missing Authorization header");
  const { payload } = await jose.jwtVerify(idToken, JWKS, {
    issuer: `https://securetoken.google.com/${FIREBASE_PROJECT_ID}`,
    audience: FIREBASE_PROJECT_ID,
  });
  return payload.sub as string;
}

// Just enough of Firestore's wire format to read two fields.
function fsValue(v: any): any {
  if (v == null) return null;
  if ("stringValue" in v) return v.stringValue;
  if ("booleanValue" in v) return v.booleanValue;
  if ("arrayValue" in v) return (v.arrayValue.values ?? []).map(fsValue);
  return null;
}

async function getProfile(uid: string, accessToken: string): Promise<Record<string, any>> {
  const res = await fetch(`${FIRESTORE_BASE}/users/${uid}/private/profile`, {
    headers: { Authorization: `Bearer ${accessToken}` },
  });
  if (res.status === 404) return {};
  if (!res.ok) throw new Error(`Firestore read failed: ${await res.text()}`);
  const data = await res.json();
  const out: Record<string, any> = {};
  for (const k in data.fields ?? {}) out[k] = fsValue(data.fields[k]);
  return out;
}

async function removeStaleToken(uid: string, deadToken: string, accessToken: string) {
  try {
    const profile = await getProfile(uid, accessToken);
    const remaining: string[] = (profile.fcmTokens ?? []).filter((t: string) => t !== deadToken);
    await fetch(`${FIRESTORE_BASE}/users/${uid}/private/profile?updateMask.fieldPaths=fcmTokens`, {
      method: "PATCH",
      headers: { Authorization: `Bearer ${accessToken}`, "Content-Type": "application/json" },
      body: JSON.stringify({
        fields: { fcmTokens: { arrayValue: { values: remaining.map((t) => ({ stringValue: t })) } } },
      }),
    });
  } catch (_) {
    // Best-effort — a dead token just gets retried next time.
  }
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  try {
    const uid = await verifyIdToken(req);
    const body = await req.json();

    const event = String(body.event ?? "");
    const makeText = EVENT_TEXT[event];
    if (!makeText) {
      return new Response(JSON.stringify({ error: "Unknown event" }), { status: 400, headers: CORS });
    }
    const deviceLabel = String(body.deviceLabel ?? "a device").slice(0, 60);
    // The phone that just did the thing doesn't need a notification about
    // its own action — the app passes its own FCM token so we can skip it.
    const excludeToken = typeof body.excludeToken === "string" ? body.excludeToken : null;

    const accessToken = await getAccessToken();
    const profile = await getProfile(uid, accessToken);
    const tokens: string[] = (profile.fcmTokens ?? []).filter((t: string) => t !== excludeToken);
    if (tokens.length === 0) {
      return new Response(JSON.stringify({ sent: 0, total: 0 }), { status: 200, headers: CORS });
    }

    // Same custom-sound channel send-push uses, so these buzz the way the
    // person chose in Settings > Notifications > Sounds.
    const rawChannelId = profile.notificationChannelId;
    const channelId =
      typeof rawChannelId === "string" && /^[A-Za-z0-9_]{1,64}$/.test(rawChannelId) ? rawChannelId : null;

    const results = await Promise.all(
      tokens.map(async (token) => {
        const res = await fetch(`https://fcm.googleapis.com/v1/projects/${FIREBASE_PROJECT_ID}/messages:send`, {
          method: "POST",
          headers: { Authorization: `Bearer ${accessToken}`, "Content-Type": "application/json" },
          body: JSON.stringify({
            message: {
              token,
              notification: { title: "NWisp Chat", body: makeText(deviceLabel) },
              data: { type: "security_event", event },
              android: {
                priority: "high",
                ...(channelId ? { notification: { channel_id: channelId } } : {}),
              },
              apns: { headers: { "apns-priority": "10" } },
            },
          }),
        });
        if (!res.ok) {
          const errText = await res.text();
          if (errText.includes("UNREGISTERED") || errText.includes("NOT_FOUND")) {
            await removeStaleToken(uid, token, accessToken);
          }
        }
        return res.ok;
      }),
    );

    return new Response(JSON.stringify({ sent: results.filter(Boolean).length, total: tokens.length }), {
      status: 200,
      headers: CORS,
    });
  } catch (err) {
    return new Response(JSON.stringify({ error: String(err) }), { status: 401, headers: CORS });
  }
});
