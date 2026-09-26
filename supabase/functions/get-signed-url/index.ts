import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import * as jose from "https://esm.sh/jose@5";

const FIREBASE_PROJECT_ID = Deno.env.get("FIREBASE_PROJECT_ID")!; // set this secret to "nwisp-c2f49" in Supabase dashboard
const JWKS = jose.createRemoteJWKSet(
  new URL("https://www.googleapis.com/service_accounts/v1/jwk/securetoken@system.gserviceaccount.com")
);

const supabase = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!
);

// --- Feature: server-enforced blocked-user story visibility -------------
// Reuses the exact same Firebase-service-account pattern send-push already
// uses (see its own file) to read the narrow `blocks/{blockerUid}_{blockedUid}`
// lookup doc directly, bypassing Firestore security rules the way a
// service-role key bypasses Supabase RLS — this function needs to check a
// block between TWO OTHER people (the story owner and the caller), not
// just "did the story owner block ME", which is all a client-side
// Firestore read could ever safely check for itself.
//
// These two secrets are OPTIONAL for get-signed-url specifically: if
// they're not set (e.g. a project that hasn't wired up push notifications
// yet), the block check is skipped entirely rather than breaking every
// story download — see [checkStoryNotBlocked] below. Set them the same
// way send-push's secrets are set (supabase/SETUP.md) to turn this on.
const FIREBASE_SERVICE_ACCOUNT_EMAIL = Deno.env.get("FIREBASE_SERVICE_ACCOUNT_EMAIL");
const FIREBASE_SERVICE_ACCOUNT_PRIVATE_KEY = Deno.env.get("FIREBASE_SERVICE_ACCOUNT_PRIVATE_KEY")?.replace(/\\n/g, "\n");
const TOKEN_URL = "https://oauth2.googleapis.com/token";
const FIRESTORE_BASE = `https://firestore.googleapis.com/v1/projects/${FIREBASE_PROJECT_ID}/databases/(default)/documents`;

let cachedToken: { token: string; expiresAt: number } | null = null;

async function getFirestoreAccessToken(): Promise<string> {
  if (cachedToken && cachedToken.expiresAt > Date.now() + 30_000) {
    return cachedToken.token;
  }
  const privateKey = await jose.importPKCS8(FIREBASE_SERVICE_ACCOUNT_PRIVATE_KEY!, "RS256");
  const now = Math.floor(Date.now() / 1000);
  const assertion = await new jose.SignJWT({ scope: "https://www.googleapis.com/auth/datastore" })
    .setProtectedHeader({ alg: "RS256" })
    .setIssuer(FIREBASE_SERVICE_ACCOUNT_EMAIL!)
    .setSubject(FIREBASE_SERVICE_ACCOUNT_EMAIL!)
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

async function blockDocExists(blockId: string, accessToken: string): Promise<boolean> {
  const res = await fetch(`${FIRESTORE_BASE}/blocks/${blockId}`, {
    headers: { Authorization: `Bearer ${accessToken}` },
  });
  if (res.status === 404) return false;
  if (!res.ok) throw new Error(`Firestore read failed (blocks/${blockId}): ${await res.text()}`);
  return true;
}

/// Rejects a story-media download if either person has blocked the other.
/// Only applies to `stories/<ownerUid>/...` paths, and only when the
/// caller isn't the story's own owner (viewing your own story never needs
/// this check). Fails OPEN (does nothing) if the Firebase service-account
/// secrets above aren't configured, or if the Firestore call itself
/// errors — a misconfiguration here shouldn't turn into every story in
/// the app failing to load; it just means this specific protection isn't
/// active yet until those secrets are set.
async function checkStoryNotBlocked(path: string, callerUid: string): Promise<void> {
  const segments = path.split("/");
  if (segments[0] !== "stories" || segments.length < 2) return;
  const ownerUid = segments[1];
  if (ownerUid === callerUid) return;
  if (!FIREBASE_SERVICE_ACCOUNT_EMAIL || !FIREBASE_SERVICE_ACCOUNT_PRIVATE_KEY) return;

  try {
    const accessToken = await getFirestoreAccessToken();
    const [ownerBlockedCaller, callerBlockedOwner] = await Promise.all([
      blockDocExists(`${ownerUid}_${callerUid}`, accessToken),
      blockDocExists(`${callerUid}_${ownerUid}`, accessToken),
    ]);
    if (ownerBlockedCaller || callerBlockedOwner) {
      throw new BlockedForStoryError();
    }
  } catch (err) {
    if (err instanceof BlockedForStoryError) throw err;
    // Firestore/network hiccup checking the block — fail open (see doc
    // comment above), don't block every story download over it.
  }
}

class BlockedForStoryError extends Error {}

// BUGFIX: the previous version verified the caller's Firebase ID token but
// never checked that `path` actually belonged to that caller. Any signed-in
// user could pass ANY bucket/path and get a valid signed *upload* URL for
// it - i.e. anyone could overwrite or vandalize another user's storage
// objects (avatars/stories/future chat media) just by knowing or guessing
// their uid + filename. Uploads are now hard-restricted to the caller's own
// path prefix ("<folder>/<uid>/...", the convention already used by
// StoryService and friends).
//
// Downloads are otherwise left permissive, matching the existing Firestore
// rule that lets any signed-in user read story documents (`allow read: if
// isSignedIn()`) - the one exception is [checkStoryNotBlocked] above,
// which specifically rejects a story-media download between two people
// who've blocked each other, since that check can't safely be done
// client-side (it needs to check a block between two OTHER people, not
// just "did they block me").
Deno.serve(async (req) => {
  try {
    const authHeader = req.headers.get("Authorization") || "";
    const idToken = authHeader.replace("Bearer ", "");

    const { payload } = await jose.jwtVerify(idToken, JWKS, {
      issuer: `https://securetoken.google.com/${FIREBASE_PROJECT_ID}`,
      audience: FIREBASE_PROJECT_ID,
    });
    const uid = payload.sub as string;

    const { bucket, path, mode } = await req.json();

    if (typeof bucket !== "string" || typeof path !== "string" || typeof mode !== "string") {
      return new Response(JSON.stringify({ error: "Invalid request" }), { status: 400 });
    }

    // Expected path shape everywhere in the app is "<prefix>/<uid>/<rest>"
    // (e.g. "stories/<uid>/172839...", "avatars/<uid>.jpg"). Pull out the
    // owner segment so we can check it against the caller's own uid.
    const segments = path.split("/");
    const ownerSegment = segments.length > 1 ? segments[1] : segments[0];

    if (mode === "upload") {
      if (ownerSegment !== uid) {
        return new Response(
          JSON.stringify({ error: "You can only upload to your own storage path." }),
          { status: 403 },
        );
      }
      const { data, error } = await supabase.storage.from(bucket).createSignedUploadUrl(path);
      if (error) throw error;
      return Response.json({ uid, ...data });
    } else if (mode === "download") {
      try {
        await checkStoryNotBlocked(path, uid);
      } catch (err) {
        if (err instanceof BlockedForStoryError) {
          return new Response(
            JSON.stringify({ error: "You can't view this story." }),
            { status: 403 },
          );
        }
        throw err;
      }
      const { data, error } = await supabase.storage.from(bucket).createSignedUrl(path, 3600);
      if (error) throw error;
      return Response.json({ uid, signedUrl: data.signedUrl });
    } else if (mode === "delete") {
      // Feature: Stories — the story's owner deletes their own story
      // media directly (either a manual delete, or StoryService's
      // best-effort cleanup of a just-expired story — see that method's
      // comment). Same simple path-prefix check as uploads use, since
      // here the deleter IS the uid in the path.
      if (segments[0] === "stories" && ownerSegment === uid) {
        const { error } = await supabase.storage.from(bucket).remove([path]);
        if (error) throw error;
        return Response.json({ uid, deleted: true });
      }
      // Chat media is meant to be forward-only, never a permanent copy on
      // the server (see message_relay_service.dart) - the recipient's
      // device calls this right after it finishes downloading, decrypting,
      // and saving its own local copy. Authorization here can't be a
      // simple path-prefix check like uploads use, because the deleter
      // (the recipient) isn't the uid in the path (the sender's uid is).
      // Instead we check message_relay directly (service-role, bypasses
      // RLS) for a row that actually references this exact path AND has
      // the caller as either its sender or its recipient.
      const { data: rows, error: relayError } = await supabase
        .from("message_relay")
        .select("sender_uid, recipient_uid")
        .eq("media_path", path)
        .limit(1);
      if (relayError) throw relayError;
      const row = rows?.[0];
      const authorized = row && (row.sender_uid === uid || row.recipient_uid === uid);
      if (!authorized) {
        return new Response(
          JSON.stringify({ error: "You can only delete media from your own messages." }),
          { status: 403 },
        );
      }
      const { error } = await supabase.storage.from(bucket).remove([path]);
      if (error) throw error;
      return Response.json({ uid, deleted: true });
    } else {
      return new Response(JSON.stringify({ error: "Unknown mode" }), { status: 400 });
    }
  } catch (err) {
    return new Response(JSON.stringify({ error: String(err) }), { status: 401 });
  }
});
