import * as jose from "https://esm.sh/jose@5";

// SECURITY FIX (2026-09-24 audit) — the missing piece that makes
// supabase/migrations/0008_message_relay_rls.sql's auth.uid()-based
// policies actually work. Read that migration's header comment first for
// the full picture; this file is the "small privileged service" it
// flags as not yet built.
//
// WHY THIS HAS TO BE A SEPARATE PRIVILEGED SERVICE, NOT SOMETHING THE APP
// DOES ITSELF: Supabase's Third-Party Auth (Firebase) integration requires
// every accepted Firebase ID token to carry a `role: "authenticated"`
// custom claim (see https://supabase.com/docs/guides/auth/third-party/firebase-auth).
// That claim can only be SET using a Google service-account credential with
// admin rights over the Firebase project — mobile/lib client code can
// never set its own claims, by design, or literally anyone could grant
// themselves any role they like. This function IS that privileged step:
// it verifies who is asking (their own, real Firebase ID token) and then
// sets the claim for THAT uid only — never an arbitrary one a caller
// could pass in.
//
// WHEN THE APP CALLS THIS: once, right after AuthService.registerWithEmail
// and AuthService.finishLogin succeed (see the calls added in
// mobile/lib/services/auth_service.dart). Calling it again for someone who
// already has the claim is harmless — it's a small extra round trip, not a
// correctness problem, which is what makes "just call it on every
// login too" a safe way to backfill every account that existed before
// this fix, with no separate bulk migration script needed.
//
// REQUIRED SECRETS (Supabase dashboard > Edge Functions > set-auth-role >
// Secrets — the first three are the exact same ones send-push and
// get-signed-url already use, so if those are working, you very likely
// already have them):
//   FIREBASE_PROJECT_ID               e.g. "nwisp-c2f49"
//   FIREBASE_SERVICE_ACCOUNT_EMAIL     the service account's client_email
//   FIREBASE_SERVICE_ACCOUNT_PRIVATE_KEY  its private_key (paste the whole
//                                      PEM block, including the ---BEGIN/
//                                      END--- lines; literal \n sequences
//                                      are converted below, same as the
//                                      other two functions do)
//
// The service account's own Google Cloud IAM role needs to be able to mint
// a token with the `identitytoolkit` scope for this Firebase project —
// the "Firebase Authentication Admin" IAM role (or broader Editor/Owner,
// already required for the service account send-push/get-signed-url use)
// covers this.

const FIREBASE_PROJECT_ID = Deno.env.get("FIREBASE_PROJECT_ID")!;
const FIREBASE_SERVICE_ACCOUNT_EMAIL = Deno.env.get("FIREBASE_SERVICE_ACCOUNT_EMAIL")!;
const FIREBASE_SERVICE_ACCOUNT_PRIVATE_KEY = Deno.env.get("FIREBASE_SERVICE_ACCOUNT_PRIVATE_KEY")!.replace(/\\n/g, "\n");

const TOKEN_URL = "https://oauth2.googleapis.com/token";
const IDENTITY_TOOLKIT_BASE = "https://identitytoolkit.googleapis.com/v1";

// Verifies the CALLER's own Firebase ID token — same JWKS this project's
// get-signed-url function already uses. This is what stops anyone from
// setting the claim for an account that isn't their own: the uid this
// function acts on always comes from a verified token's own `sub` claim,
// never from anything the request body says.
const CALLER_JWKS = jose.createRemoteJWKSet(
  new URL("https://www.googleapis.com/service_accounts/v1/jwk/securetoken@system.gserviceaccount.com"),
);

let cachedAdminToken: { token: string; expiresAt: number } | null = null;

// Same Google service-account OAuth2 "JWT bearer" exchange
// get-signed-url's getFirestoreAccessToken already uses for Firestore —
// only the requested `scope` differs (identitytoolkit, not datastore),
// because this needs permission to edit accounts, not read Firestore.
async function getIdentityToolkitAccessToken(): Promise<string> {
  if (cachedAdminToken && cachedAdminToken.expiresAt > Date.now() + 30_000) {
    return cachedAdminToken.token;
  }
  const privateKey = await jose.importPKCS8(FIREBASE_SERVICE_ACCOUNT_PRIVATE_KEY, "RS256");
  const now = Math.floor(Date.now() / 1000);
  const assertion = await new jose.SignJWT({ scope: "https://www.googleapis.com/auth/identitytoolkit" })
    .setProtectedHeader({ alg: "RS256" })
    .setIssuer(FIREBASE_SERVICE_ACCOUNT_EMAIL)
    .setSubject(FIREBASE_SERVICE_ACCOUNT_EMAIL)
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
  cachedAdminToken = { token: data.access_token, expiresAt: Date.now() + data.expires_in * 1000 };
  return data.access_token;
}

// Reads this one user's CURRENT custom claims first, so the update below
// can merge `role: "authenticated"` into whatever is already there
// instead of blindly overwriting it — accounts:update's customAttributes
// replaces the whole claims object, not just one key. Nothing in this
// codebase sets any other custom claim today, but a future feature might,
// and this costs one extra read to get right rather than assume.
async function getExistingClaims(uid: string, accessToken: string): Promise<Record<string, unknown>> {
  const res = await fetch(`${IDENTITY_TOOLKIT_BASE}/accounts:lookup`, {
    method: "POST",
    headers: { Authorization: `Bearer ${accessToken}`, "Content-Type": "application/json" },
    body: JSON.stringify({ localId: [uid] }),
  });
  if (!res.ok) throw new Error(`accounts:lookup failed: ${await res.text()}`);
  const data = await res.json();
  const raw = data.users?.[0]?.customAttributes as string | undefined;
  if (!raw) return {};
  try {
    return JSON.parse(raw);
  } catch {
    return {}; // malformed existing claims shouldn't block granting this one
  }
}


// ---------------------------------------------------------------------------
// Minimum app version (the server half of "you must update").
//
// This code is written INSIDE this file on purpose: the Supabase dashboard
// bundles only this one function's folder, so it can't import a shared file.
//
// WHY: a check that lives only inside the app can be cut out of a modified
// copy. This one runs on the server. When the app's version is below
// "minSupportedVersionCode" in your update/update.json, the server refuses.
// HONEST LIMIT: the version number is sent by the app, so a skilled person
// could lie about it — this is one layer of several, not "unbreakable".
//
// SETUP: Edge Functions -> Secrets -> add UPDATE_JSON_URL = the "raw" address of
// update/update.json in your GitHub repo. Without it this check does nothing.
// If GitHub can't be reached the request is allowed through, so a GitHub
// outage can never lock everybody out.
// ---------------------------------------------------------------------------
let versionGateCache: { min: number; at: number } | null = null;

async function versionGateMinimum(): Promise<number> {
  const url = Deno.env.get("UPDATE_JSON_URL");
  if (!url) return 0;
  if (versionGateCache && Date.now() - versionGateCache.at < 60_000) return versionGateCache.min;
  try {
    const res = await fetch(url, { headers: { "Cache-Control": "no-cache" } });
    if (!res.ok) return versionGateCache?.min ?? 0;
    const json = await res.json();
    const min = Number(json.minSupportedVersionCode ?? 0);
    versionGateCache = { min: Number.isFinite(min) ? min : 0, at: Date.now() };
    return versionGateCache.min;
  } catch (_) {
    return versionGateCache?.min ?? 0;
  }
}

/// Returns a ready-made 426 response if this app version is too old, else null.
async function rejectIfOutdated(req: Request): Promise<Response | null> {
  const min = await versionGateMinimum();
  if (min <= 0) return null;
  const sent = Number(req.headers.get("x-app-version") ?? "0");
  // No version at all = a very old build from before this check existed.
  if (!Number.isFinite(sent) || sent < min) {
    return new Response(JSON.stringify({ error: "update_required", minVersion: min }), {
      status: 426,
      headers: { "Content-Type": "application/json" },
    });
  }
  return null;
}

Deno.serve(async (req) => {
  try {
    // Feature: minimum app version (see "Minimum app version" above).
    const outdated = await rejectIfOutdated(req);
    if (outdated) return outdated;
    const authHeader = req.headers.get("Authorization") || "";
    const idToken = authHeader.replace("Bearer ", "");

    // This is a verification of the CALLER, not the account being
    // modified — they are always the same uid here, by design (see the
    // doc comment above `CALLER_JWKS`).
    const { payload } = await jose.jwtVerify(idToken, CALLER_JWKS, {
      issuer: `https://securetoken.google.com/${FIREBASE_PROJECT_ID}`,
      audience: FIREBASE_PROJECT_ID,
    });
    const uid = payload.sub as string;

    const accessToken = await getIdentityToolkitAccessToken();
    const existingClaims = await getExistingClaims(uid, accessToken);

    if (existingClaims["role"] === "authenticated") {
      // Already set (e.g. this is a returning login, not a first-ever
      // call) — nothing to do. Saves a write, and makes this endpoint
      // idempotent to call on every login without concern.
      return Response.json({ uid, alreadySet: true });
    }

    const mergedClaims = { ...existingClaims, role: "authenticated" };
    const updateRes = await fetch(`${IDENTITY_TOOLKIT_BASE}/accounts:update`, {
      method: "POST",
      headers: { Authorization: `Bearer ${accessToken}`, "Content-Type": "application/json" },
      body: JSON.stringify({ localId: uid, customAttributes: JSON.stringify(mergedClaims) }),
    });
    if (!updateRes.ok) throw new Error(`accounts:update failed: ${await updateRes.text()}`);

    // The claim only takes effect on this person's NEXT id token — the one
    // they're using right now (the one just verified above) was minted
    // before this claim existed. The client must force-refresh its token
    // after this call returns success (see AuthService, which does
    // `getIdToken(true)` right after calling this function) or Supabase
    // will keep seeing the old, claim-less token until it naturally
    // expires (Firebase ID tokens live for up to 1 hour).
    return Response.json({ uid, alreadySet: false });
  } catch (err) {
    return new Response(JSON.stringify({ error: String(err) }), { status: 401 });
  }
});
