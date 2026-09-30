import * as jose from "https://esm.sh/jose@5";

// Feature: voice calls. When someone starts a call, the app calls this
// function so the other person's phone shows an "Incoming voice call"
// notification even if NWisp is closed. Tapping it opens the app, which then
// shows the ringing screen (as long as the call is still ringing).
//
// Same free-tier pieces as send-security-push: this Edge Function + the FCM
// HTTP v1 API. No Firebase Cloud Functions, no Blaze plan.
//
// Safety: the caller is identified by their Firebase ID token. Before any
// push is sent, the function reads calls/{callId} from Firestore and only
// continues if that call really was created by THIS caller, is addressed to
// the named person, and is still "ringing" — so nobody can use it to spam
// fake call alerts.
//
// Secrets (already set for send-push): FIREBASE_PROJECT_ID,
// FIREBASE_SERVICE_ACCOUNT_EMAIL, FIREBASE_SERVICE_ACCOUNT_PRIVATE_KEY

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

function fsValue(v: any): any {
  if (v == null) return null;
  if ("stringValue" in v) return v.stringValue;
  if ("booleanValue" in v) return v.booleanValue;
  if ("arrayValue" in v) return (v.arrayValue.values ?? []).map(fsValue);
  return null;
}

async function getDoc(path: string, accessToken: string): Promise<Record<string, any> | null> {
  const res = await fetch(`${FIRESTORE_BASE}/${path}`, { headers: { Authorization: `Bearer ${accessToken}` } });
  if (res.status === 404) return null;
  if (!res.ok) throw new Error(`Firestore read failed: ${await res.text()}`);
  const data = await res.json();
  const out: Record<string, any> = {};
  for (const k in data.fields ?? {}) out[k] = fsValue(data.fields[k]);
  return out;
}

async function removeStaleToken(uid: string, deadToken: string, accessToken: string) {
  try {
    const profile = (await getDoc(`users/${uid}/private/profile`, accessToken)) ?? {};
    const remaining: string[] = (profile.fcmTokens ?? []).filter((t: string) => t !== deadToken);
    await fetch(`${FIRESTORE_BASE}/users/${uid}/private/profile?updateMask.fieldPaths=fcmTokens`, {
      method: "PATCH",
      headers: { Authorization: `Bearer ${accessToken}`, "Content-Type": "application/json" },
      body: JSON.stringify({ fields: { fcmTokens: { arrayValue: { values: remaining.map((t) => ({ stringValue: t })) } } } }),
    });
  } catch (_) {}
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  try {
    const callerUid = await verifyIdToken(req);
    const body = await req.json();
    const callId = String(body.callId ?? "");
    const calleeUid = String(body.calleeUid ?? "");
    if (!/^[A-Za-z0-9]{10,40}$/.test(callId) || !/^[A-Za-z0-9]{10,40}$/.test(calleeUid)) {
      return new Response(JSON.stringify({ error: "Bad request" }), { status: 400, headers: CORS });
    }

    const accessToken = await getAccessToken();
    const call = await getDoc(`calls/${callId}`, accessToken);
    if (!call || call.callerUid !== callerUid || call.calleeUid !== calleeUid || call.status !== "ringing") {
      return new Response(JSON.stringify({ error: "No such ringing call" }), { status: 403, headers: CORS });
    }
    const callerName = String(call.callerName ?? "Someone").slice(0, 40);

    const profile = (await getDoc(`users/${calleeUid}/private/profile`, accessToken)) ?? {};
    const tokens: string[] = profile.fcmTokens ?? [];
    if (tokens.length === 0) {
      return new Response(JSON.stringify({ sent: 0, total: 0 }), { status: 200, headers: CORS });
    }

    const results = await Promise.all(
      tokens.map(async (token) => {
        const res = await fetch(`https://fcm.googleapis.com/v1/projects/${FIREBASE_PROJECT_ID}/messages:send`, {
          method: "POST",
          headers: { Authorization: `Bearer ${accessToken}`, "Content-Type": "application/json" },
          body: JSON.stringify({
            message: {
              token,
              notification: { title: "Incoming voice call", body: `${callerName} is calling you on NWisp` },
              data: { type: "incoming_call", callId },
              android: { priority: "high", ttl: "30s" },
              apns: { headers: { "apns-priority": "10" } },
            },
          }),
        });
        if (!res.ok) {
          const errText = await res.text();
          if (errText.includes("UNREGISTERED") || errText.includes("NOT_FOUND")) {
            await removeStaleToken(calleeUid, token, accessToken);
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
