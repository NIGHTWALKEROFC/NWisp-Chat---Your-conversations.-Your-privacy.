import * as jose from "https://esm.sh/jose@5";

// Turns a new row in `message_relay` into a push notification, using ONLY
// free-tier pieces: this Edge Function (Supabase free plan), a Database
// Webhook (also free, see supabase/SETUP.md), and the FCM HTTP v1 API
// (unconditionally free on Firebase - no Blaze/billing required). No
// Firebase Cloud Functions anywhere in this flow, since those require a
// Blaze billing account even to make this exact kind of outbound call.

const FIREBASE_PROJECT_ID = Deno.env.get("FIREBASE_PROJECT_ID")!;
const SERVICE_ACCOUNT_EMAIL = Deno.env.get("FIREBASE_SERVICE_ACCOUNT_EMAIL")!;
// Accept the private key whether it was pasted with real newlines or with
// literal "\n" escapes (both happen depending on how it's pasted into the
// Supabase dashboard) - normalize either way.
const SERVICE_ACCOUNT_PRIVATE_KEY = Deno.env.get("FIREBASE_SERVICE_ACCOUNT_PRIVATE_KEY")!.replace(/\\n/g, "\n");
const WEBHOOK_SECRET = Deno.env.get("PUSH_WEBHOOK_SECRET")!;

const TOKEN_URL = "https://oauth2.googleapis.com/token";
const FIRESTORE_BASE = `https://firestore.googleapis.com/v1/projects/${FIREBASE_PROJECT_ID}/databases/(default)/documents`;

// A service-account access token is valid for an hour - cache it across
// invocations of this same warm Edge Function instance instead of doing a
// fresh JWT-bearer exchange on every single message.
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

// --- tiny Firestore REST helpers (decode/encode the verbose {fields:{...}}
// wire format) - just enough to read a doc and patch one array field. ---
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

/// Best-effort cleanup: if FCM says a token is dead (app uninstalled, etc),
/// drop it from that user's fcmTokens array so we stop retrying it forever.
async function removeStaleToken(uid: string, deadToken: string, accessToken: string) {
  try {
    const profile = await getDoc(`users/${uid}/private/profile`, accessToken);
    const remaining: string[] = (profile?.fcmTokens ?? []).filter((t: string) => t !== deadToken);
    await fetch(`${FIRESTORE_BASE}/users/${uid}/private/profile?updateMask.fieldPaths=fcmTokens`, {
      method: "PATCH",
      headers: { Authorization: `Bearer ${accessToken}`, "Content-Type": "application/json" },
      body: JSON.stringify({
        fields: { fcmTokens: { arrayValue: { values: remaining.map((t) => ({ stringValue: t })) } } },
      }),
    });
  } catch (_) {
    // Not critical - worst case this dead token just gets retried next time too.
  }
}

// Only actual message content is worth a push. Receipts/deletes/clears/
// reactions get picked up next time the recipient's app is open (see
// MessageRelayService._catchUp) - pushing every one of those would be
// noisy for very little benefit.
const NOTIFIABLE_TYPES = new Set(["text", "image", "video", "voice"]);

Deno.serve(async (req) => {
  try {
    // The Database Webhook is configured (see supabase/SETUP.md) to send
    // this same secret as a header on every call, so random requests to
    // this URL can't trigger pushes or burn through your FCM quota.
    if (req.headers.get("X-Webhook-Secret") !== WEBHOOK_SECRET) {
      return new Response("Forbidden", { status: 403 });
    }

    const { record } = await req.json();
    if (!record || !NOTIFIABLE_TYPES.has(record.message_type)) {
      return new Response("Skipped", { status: 200 });
    }

    const accessToken = await getAccessToken();

    // Respect the recipient's mute setting (see ConversationService/
    // GroupService's setMuted — a "mutedBy" array on the conversation or
    // group doc) before doing anything else. Group ids are always
    // "group_<uuid>" (see GroupService.newGroupId in the app), so that
    // prefix is what decides which collection to read.
    const conversationId = String(record.conversation_id ?? "");
    const isGroupConversation = conversationId.startsWith("group_");
    const convoDoc = await getDoc(
      isGroupConversation ? `groups/${conversationId}` : `conversations/${conversationId}`,
      accessToken,
    );
    const mutedBy: string[] = (convoDoc?.mutedBy as string[] | undefined) ?? [];
    if (mutedBy.includes(record.recipient_uid)) {
      return new Response("Muted", { status: 200 });
    }

    const [recipientProfile, sender] = await Promise.all([
      getDoc(`users/${record.recipient_uid}/private/profile`, accessToken),
      getDoc(`users/${record.sender_uid}`, accessToken),
    ]);

    const tokens: string[] = recipientProfile?.fcmTokens ?? [];
    if (tokens.length === 0) return new Response("No tokens", { status: 200 });

    const senderUsername = (sender?.username as string | undefined) ?? "Someone";
    // Deliberately generic body text - this relay never has decrypted
    // content to begin with (see message_relay_service.dart), and the
    // notification shouldn't either.
    const bodyText =
      record.message_type === "text" ? "Sent you a message" :
      record.message_type === "image" ? "Sent you a photo" :
      record.message_type === "video" ? "Sent you a video" :
      "Sent you a voice message";

    const results = await Promise.all(
      tokens.map(async (token) => {
        const res = await fetch(`https://fcm.googleapis.com/v1/projects/${FIREBASE_PROJECT_ID}/messages:send`, {
          method: "POST",
          headers: { Authorization: `Bearer ${accessToken}`, "Content-Type": "application/json" },
          body: JSON.stringify({
            message: {
              token,
              notification: { title: senderUsername, body: bodyText },
              data: {
                type: "new_message",
                conversationId: String(record.conversation_id ?? ""),
                senderUid: String(record.sender_uid ?? ""),
                senderUsername,
              },
              android: { priority: "high" },
              apns: { headers: { "apns-priority": "10" } },
            },
          }),
        });
        if (!res.ok) {
          const errText = await res.text();
          if (errText.includes("UNREGISTERED") || errText.includes("NOT_FOUND")) {
            await removeStaleToken(record.recipient_uid, token, accessToken);
          }
        }
        return res.ok;
      }),
    );

    return new Response(JSON.stringify({ sent: results.filter(Boolean).length, total: tokens.length }), { status: 200 });
  } catch (err) {
    return new Response(JSON.stringify({ error: String(err) }), { status: 500 });
  }
});
