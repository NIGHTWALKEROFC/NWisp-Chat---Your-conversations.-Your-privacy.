import * as jose from "https://esm.sh/jose@5";

// Sends a push notification ("<name> wants to add you") when someone sends a
// contact request, so the badge isn't the only way to find out.
//
// WHY AN EDGE FUNCTION AND NOT A FIREBASE TRIGGER: Firestore triggers need a
// Firebase Cloud Function, which needs a paid Blaze plan. Instead the sender's
// app calls this right after it creates the request.
//
// WHAT KEEPS IT HONEST: the caller must hold a real Firebase sign-in, and the
// function re-reads the request from Firestore itself — it must exist, be
// pending, be from the caller, be addressed to that person, and be less than
// two minutes old. It pushes at most ONCE per request. So it can't be used to
// spam anyone or to push text of the caller's choosing: the words are fixed.
//
// Respects the receiver's Do Not Disturb hours and "hide name in
// notifications" setting, like send-push does.
//
// Written to be pasted into the Supabase dashboard editor (no shared imports).
// SECRETS (the same ones send-push uses): FIREBASE_PROJECT_ID,
// FIREBASE_SERVICE_ACCOUNT_EMAIL, FIREBASE_SERVICE_ACCOUNT_PRIVATE_KEY.

const FIREBASE_PROJECT_ID = Deno.env.get("FIREBASE_PROJECT_ID")!;
const SERVICE_ACCOUNT_EMAIL = Deno.env.get("FIREBASE_SERVICE_ACCOUNT_EMAIL")!;
const SERVICE_ACCOUNT_PRIVATE_KEY = Deno.env.get("FIREBASE_SERVICE_ACCOUNT_PRIVATE_KEY")!.replace(/\\n/g, "\n");

const TOKEN_URL = "https://oauth2.googleapis.com/token";
const FIRESTORE_BASE = `https://firestore.googleapis.com/v1/projects/${FIREBASE_PROJECT_ID}/databases/(default)/documents`;

const CALLER_JWKS = jose.createRemoteJWKSet(
  new URL("https://www.googleapis.com/service_accounts/v1/jwk/securetoken@system.gserviceaccount.com"),
);

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

function fsValue(v: any): any {
  if (v == null) return null;
  if ("stringValue" in v) return v.stringValue;
  if ("booleanValue" in v) return v.booleanValue;
  if ("integerValue" in v) return Number(v.integerValue);
  if ("timestampValue" in v) return v.timestampValue;
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
  const res = await fetch(`${FIRESTORE_BASE}/${path}`, { headers: { Authorization: `Bearer ${accessToken}` } });
  if (res.status === 404) return null;
  if (!res.ok) throw new Error(`Firestore read failed (${path}): ${await res.text()}`);
  return fsFields((await res.json()).fields ?? {});
}

async function removeStaleToken(uid: string, deadToken: string, accessToken: string) {
  try {
    const profile = await getDoc(`users/${uid}/private/profile`, accessToken);
    const remaining: string[] = (profile?.fcmTokens ?? []).filter((t: string) => t !== deadToken);
    await fetch(`${FIRESTORE_BASE}/users/${uid}/private/profile?updateMask.fieldPaths=fcmTokens`, {
      method: "PATCH",
      headers: { Authorization: `Bearer ${accessToken}`, "Content-Type": "application/json" },
      body: JSON.stringify({ fields: { fcmTokens: { arrayValue: { values: remaining.map((t) => ({ stringValue: t })) } } } }),
    });
  } catch (_) { /* not critical */ }
}

Deno.serve(async (req) => {
  try {
    const idToken = (req.headers.get("Authorization") || "").replace("Bearer ", "");
    const { payload } = await jose.jwtVerify(idToken, CALLER_JWKS, {
      issuer: `https://securetoken.google.com/${FIREBASE_PROJECT_ID}`,
      audience: FIREBASE_PROJECT_ID,
    });
    const callerUid = payload.sub as string;

    const body = await req.json();
    const requestId = String(body.requestId ?? "");
    const toUid = String(body.toUid ?? "");
    if (!/^[A-Za-z0-9]{10,40}$/.test(requestId) || !/^[A-Za-z0-9]{10,40}$/.test(toUid)) {
      return Response.json({ error: "bad request" }, { status: 400 });
    }

    const accessToken = await getAccessToken();

    // Re-read the request ourselves — never trust the caller's description of it.
    const request = await getDoc(`contactRequests/${requestId}`, accessToken);
    if (!request) return Response.json({ error: "no such request" }, { status: 404 });
    if (request.fromUid !== callerUid || request.toUid !== toUid || request.status !== "pending") {
      return Response.json({ error: "request does not match" }, { status: 403 });
    }
    const created = Date.parse(String(request.createdAt ?? ""));
    if (!Number.isFinite(created) || Date.now() - created > 120_000) {
      return Response.json({ skipped: "too old" });
    }
    if (request.pushedAt) return Response.json({ skipped: "already pushed" });

    // Mark as pushed FIRST so two quick calls can't both send.
    await fetch(`${FIRESTORE_BASE}/contactRequests/${requestId}?updateMask.fieldPaths=pushedAt`, {
      method: "PATCH",
      headers: { Authorization: `Bearer ${accessToken}`, "Content-Type": "application/json" },
      body: JSON.stringify({ fields: { pushedAt: { timestampValue: new Date().toISOString() } } }),
    });

    const [recipientProfile, sender] = await Promise.all([
      getDoc(`users/${toUid}/private/profile`, accessToken),
      getDoc(`users/${callerUid}`, accessToken),
    ]);
    const tokens: string[] = recipientProfile?.fcmTokens ?? [];
    if (tokens.length === 0) return Response.json({ skipped: "no tokens" });

    // Do Not Disturb hours (same rule as send-push).
    const quiet = recipientProfile?.quietHours as
      | { enabled?: boolean; startMin?: number; endMin?: number; utcOffsetMin?: number }
      | undefined;
    if (quiet?.enabled === true && typeof quiet.startMin === "number" && typeof quiet.endMin === "number" && quiet.startMin !== quiet.endMin) {
      const nowUtc = new Date();
      const utcMinutes = nowUtc.getUTCHours() * 60 + nowUtc.getUTCMinutes();
      const offset = typeof quiet.utcOffsetMin === "number" ? quiet.utcOffsetMin : 0;
      const local = (((utcMinutes + offset) % 1440) + 1440) % 1440;
      const inQuiet = quiet.startMin < quiet.endMin ? local >= quiet.startMin && local < quiet.endMin : local >= quiet.startMin || local < quiet.endMin;
      if (inQuiet) return Response.json({ skipped: "quiet hours" });
    }

    const hideName =
      (recipientProfile?.notificationPrivacyGlobal as boolean | undefined) === true ||
      (recipientProfile?.notificationPrivacyHideContentGlobal as boolean | undefined) === true;
    const name = String(sender?.username ?? "Someone");
    const title = hideName ? "NWisp" : "New contact request";
    const text = hideName ? "You have a new request" : `${name} wants to add you`;

    const rawChannelId = recipientProfile?.notificationChannelId;
    const channelId = typeof rawChannelId === "string" && /^[A-Za-z0-9_]{1,64}$/.test(rawChannelId) ? rawChannelId : null;

    const results = await Promise.all(
      tokens.map(async (token) => {
        const res = await fetch(`https://fcm.googleapis.com/v1/projects/${FIREBASE_PROJECT_ID}/messages:send`, {
          method: "POST",
          headers: { Authorization: `Bearer ${accessToken}`, "Content-Type": "application/json" },
          body: JSON.stringify({
            message: {
              token,
              notification: { title, body: text },
              data: { type: "contact_request", senderUid: callerUid },
              android: { priority: "high", ...(channelId ? { notification: { channel_id: channelId } } : {}) },
            },
          }),
        });
        if (!res.ok) {
          const errText = await res.text();
          if (errText.includes("UNREGISTERED") || errText.includes("NOT_FOUND")) await removeStaleToken(toUid, token, accessToken);
        }
        return res.ok;
      }),
    );
    return Response.json({ sent: results.filter(Boolean).length, total: tokens.length });
  } catch (err) {
    return Response.json({ error: String(err) }, { status: 401 });
  }
});
