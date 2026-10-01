import * as jose from "https://esm.sh/jose@5";

// Feature: voice calls, group calls and secret-chat requests. When someone
// starts one, the app calls this function so the other phone(s) react even
// if NWisp is closed:
//   kind "call"          1:1 call   -> DATA-ONLY push; the app turns it into a
//                                      full-screen ringing notification
//   kind "group_call"    group call -> same, sent to every group member
//   kind "secret_invite" secret chat request -> ordinary notification with
//                                      no name in it (lock-screen safe)
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

async function tokensOf(uid: string, accessToken: string): Promise<string[]> {
  const profile = (await getDoc(`users/${uid}/private/profile`, accessToken)) ?? {};
  return profile.fcmTokens ?? [];
}

async function sendFcm(uid: string, token: string, message: Record<string, unknown>, accessToken: string): Promise<boolean> {
  const res = await fetch(`https://fcm.googleapis.com/v1/projects/${FIREBASE_PROJECT_ID}/messages:send`, {
    method: "POST",
    headers: { Authorization: `Bearer ${accessToken}`, "Content-Type": "application/json" },
    body: JSON.stringify({ message: { token, ...message } }),
  });
  if (!res.ok) {
    const errText = await res.text();
    if (errText.includes("UNREGISTERED") || errText.includes("NOT_FOUND")) {
      await removeStaleToken(uid, token, accessToken);
    }
  }
  return res.ok;
}

const ID = /^[A-Za-z0-9_-]{10,80}$/;
const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status, headers: CORS });

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  try {
    const callerUid = await verifyIdToken(req);
    const body = await req.json();
    const kind = String(body.kind ?? "call");
    const accessToken = await getAccessToken();

    // ---------------------------------------------------------- 1:1 call
    if (kind === "call") {
      const callId = String(body.callId ?? "");
      const calleeUid = String(body.calleeUid ?? "");
      if (!ID.test(callId) || !ID.test(calleeUid)) return json({ error: "Bad request" }, 400);
      const call = await getDoc(`calls/${callId}`, accessToken);
      if (!call || call.callerUid !== callerUid || call.calleeUid !== calleeUid || call.status !== "ringing") {
        return json({ error: "No such ringing call" }, 403);
      }
      const callerName = String(call.callerName ?? "Someone").slice(0, 40);
      const tokens = await tokensOf(calleeUid, accessToken);
      const results = await Promise.all(tokens.map((t) =>
        sendFcm(calleeUid, t, {
          // Data only: no "notification" block, so the app's own code runs
          // and can ring full-screen.
          data: { type: "incoming_call", callId, callerName, callerUid },
          android: { priority: "high", ttl: "30s" },
        }, accessToken)
      ));
      return json({ sent: results.filter(Boolean).length, total: tokens.length });
    }

    // -------------------------------------------------------- group call
    if (kind === "group_call") {
      const callId = String(body.callId ?? "");
      if (!ID.test(callId)) return json({ error: "Bad request" }, 400);
      const call = await getDoc(`groupCalls/${callId}`, accessToken);
      if (!call || call.starterUid !== callerUid || call.status !== "active") {
        return json({ error: "No such group call" }, 403);
      }
      const members: string[] = (call.members ?? []).filter((m: string) => m !== callerUid).slice(0, 40);
      const callerName = String(call.starterName ?? "Someone").slice(0, 40);
      const groupName = String(call.groupName ?? "a group").slice(0, 40);
      let sent = 0;
      let total = 0;
      await Promise.all(members.map(async (uid) => {
        const tokens = await tokensOf(uid, accessToken);
        total += tokens.length;
        const r = await Promise.all(tokens.map((t) =>
          sendFcm(uid, t, {
            data: { type: "incoming_group_call", callId, callerName, groupName },
            android: { priority: "high", ttl: "30s" },
          }, accessToken)
        ));
        sent += r.filter(Boolean).length;
      }));
      return json({ sent, total });
    }

    // ------------------------------------------------------ secret chat
    if (kind === "secret_invite") {
      const chatId = String(body.chatId ?? "");
      const inviteeUid = String(body.inviteeUid ?? "");
      if (!ID.test(chatId) || !ID.test(inviteeUid)) return json({ error: "Bad request" }, 400);
      const chat = await getDoc(`secretChats/${chatId}`, accessToken);
      if (!chat || chat.initiator !== callerUid || chat.invitee !== inviteeUid || chat.status !== "requested") {
        return json({ error: "No such secret chat request" }, 403);
      }
      const tokens = await tokensOf(inviteeUid, accessToken);
      const results = await Promise.all(tokens.map((t) =>
        sendFcm(inviteeUid, t, {
          // No name, on purpose: this can show on a locked screen.
          notification: { title: "NWisp", body: "Secret chat request — open NWisp to see who." },
          data: { type: "secret_invite", chatId },
          android: { priority: "high", ttl: "60s" },
        }, accessToken)
      ));
      return json({ sent: results.filter(Boolean).length, total: tokens.length });
    }

    return json({ error: "Unknown kind" }, 400);
  } catch (err) {
    return json({ error: String(err) }, 401);
  }
});
