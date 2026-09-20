// Shared by send-signup-otp, verify-signup-otp, confirm-verified-email and
// send-password-reset. Same two things every one of those functions needs:
//
//   1. verifyIdToken(req)  — check the Firebase ID token the app sent us
//      (identical JWKS check get-signed-url already does), so we know
//      which uid/email is really calling us.
//
//   2. getIdentityToolkitAccessToken() — an OAuth2 access token for the
//      SAME Firebase service account send-push/get-signed-url already use,
//      just with a different scope (identitytoolkit instead of
//      datastore/messaging). This is what lets a server call:
//        - accounts:update      (mark an email verified)
//        - accounts:sendOobCode (generate a password-reset link WITHOUT
//          Firebase sending its own email for it)
//      This is exactly what the Firebase Admin SDK's updateUser() and
//      generatePasswordResetLink() do under the hood — we're just calling
//      the same REST API directly, the same way the rest of this repo's
//      Edge Functions already call Firestore/FCM directly instead of
//      pulling in the (Node-only) firebase-admin package.
//
// Needs THREE secrets already used elsewhere in this project:
//   FIREBASE_PROJECT_ID
//   FIREBASE_SERVICE_ACCOUNT_EMAIL
//   FIREBASE_SERVICE_ACCOUNT_PRIVATE_KEY
// ...plus ONE new one-time IAM step: the service account needs the
// "Firebase Authentication Admin" role in Google Cloud IAM (it almost
// certainly only has Firestore/Messaging roles today). See EMAIL_SETUP.md
// step 3 — this is a free IAM role, not a Blaze/billing requirement.

import * as jose from "https://esm.sh/jose@5";

const FIREBASE_PROJECT_ID = Deno.env.get("FIREBASE_PROJECT_ID")!;
const SERVICE_ACCOUNT_EMAIL = Deno.env.get("FIREBASE_SERVICE_ACCOUNT_EMAIL")!;
const SERVICE_ACCOUNT_PRIVATE_KEY = Deno.env.get("FIREBASE_SERVICE_ACCOUNT_PRIVATE_KEY")!.replace(/\\n/g, "\n");

const TOKEN_URL = "https://oauth2.googleapis.com/token";
const JWKS = jose.createRemoteJWKSet(
  new URL("https://www.googleapis.com/service_accounts/v1/jwk/securetoken@system.gserviceaccount.com"),
);

let cachedToken: { token: string; expiresAt: number } | null = null;

export async function getIdentityToolkitAccessToken(): Promise<string> {
  if (cachedToken && cachedToken.expiresAt > Date.now() + 30_000) {
    return cachedToken.token;
  }
  const privateKey = await jose.importPKCS8(SERVICE_ACCOUNT_PRIVATE_KEY, "RS256");
  const now = Math.floor(Date.now() / 1000);
  const assertion = await new jose.SignJWT({
    scope: "https://www.googleapis.com/auth/identitytoolkit",
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

export class AuthTokenError extends Error {}

/** Verifies the caller's Firebase ID token (sent as `Authorization: Bearer
 *  <token>`) and returns their uid + email. Throws AuthTokenError if it's
 *  missing/invalid/expired. */
export async function verifyIdToken(req: Request): Promise<{ uid: string; email: string | null }> {
  const authHeader = req.headers.get("Authorization") || "";
  const idToken = authHeader.replace("Bearer ", "");
  if (!idToken) throw new AuthTokenError("Missing Authorization header");
  try {
    const { payload } = await jose.jwtVerify(idToken, JWKS, {
      issuer: `https://securetoken.google.com/${FIREBASE_PROJECT_ID}`,
      audience: FIREBASE_PROJECT_ID,
    });
    return { uid: payload.sub as string, email: (payload.email as string | undefined) ?? null };
  } catch (err) {
    throw new AuthTokenError(String(err));
  }
}

/** Marks `uid`'s email as verified via the Identity Toolkit admin API —
 *  the server-side equivalent of the user clicking a "verify your email"
 *  link, except we already confirmed the OTP ourselves. */
export async function markEmailVerified(uid: string): Promise<void> {
  const accessToken = await getIdentityToolkitAccessToken();
  const res = await fetch("https://identitytoolkit.googleapis.com/v1/accounts:update", {
    method: "POST",
    headers: { Authorization: `Bearer ${accessToken}`, "Content-Type": "application/json" },
    body: JSON.stringify({ localId: uid, emailVerified: true }),
  });
  if (!res.ok) throw new Error(`accounts:update failed: ${await res.text()}`);
}

/** Sets a new password on `uid`'s Firebase Auth account via the Identity
 *  Toolkit admin API — used by password-reset-otp once the emailed code has
 *  been verified. The person never needs to know the old password. */
export async function setUserPassword(uid: string, newPassword: string): Promise<void> {
  const accessToken = await getIdentityToolkitAccessToken();
  const res = await fetch("https://identitytoolkit.googleapis.com/v1/accounts:update", {
    method: "POST",
    headers: { Authorization: `Bearer ${accessToken}`, "Content-Type": "application/json" },
    body: JSON.stringify({ localId: uid, password: newPassword }),
  });
  if (!res.ok) throw new Error(`accounts:update (password) failed: ${await res.text()}`);
}

/** Looks a user up by email via the Identity Toolkit admin API. Returns
 *  null if no account has that email (used so send-password-reset can
 *  quietly no-op for unknown emails instead of leaking which emails are
 *  registered). */
export async function findUserByEmail(email: string): Promise<{ localId: string } | null> {
  const accessToken = await getIdentityToolkitAccessToken();
  const res = await fetch("https://identitytoolkit.googleapis.com/v1/accounts:lookup", {
    method: "POST",
    headers: { Authorization: `Bearer ${accessToken}`, "Content-Type": "application/json" },
    body: JSON.stringify({ email: [email] }),
  });
  if (!res.ok) throw new Error(`accounts:lookup failed: ${await res.text()}`);
  const data = await res.json();
  const user = data.users?.[0];
  return user ? { localId: user.localId } : null;
}

/** Resolves what a person typed on the Reset password screen — an EMAIL or
 *  a USERNAME — to the account it belongs to. Returns null if nothing matches.
 *
 *  Usernames live in Firestore at usernames/{lowercase-name} -> { uid }, and
 *  your firestore.rules already make that collection publicly readable (the
 *  signup screen relies on it to check availability), so it's read through
 *  Firestore's plain REST endpoint with no token. The uid is then turned into
 *  an email with the Identity Toolkit admin API. */
export async function resolveAccount(identifier: string): Promise<{ localId: string; email: string } | null> {
  const typed = identifier.trim();
  if (!typed) return null;
  const accessToken = await getIdentityToolkitAccessToken();

  let query: Record<string, string[]>;
  if (typed.includes("@")) {
    query = { email: [typed.toLowerCase()] };
  } else {
    const name = typed.toLowerCase();
    const res = await fetch(
      `https://firestore.googleapis.com/v1/projects/${FIREBASE_PROJECT_ID}/databases/(default)/documents/usernames/${encodeURIComponent(name)}`,
    );
    if (res.status === 404) return null;
    if (!res.ok) throw new Error(`usernames lookup failed: ${await res.text()}`);
    const doc = await res.json();
    const uid = doc?.fields?.uid?.stringValue as string | undefined;
    if (!uid) return null;
    query = { localId: [uid] };
  }

  const res = await fetch("https://identitytoolkit.googleapis.com/v1/accounts:lookup", {
    method: "POST",
    headers: { Authorization: `Bearer ${accessToken}`, "Content-Type": "application/json" },
    body: JSON.stringify(query),
  });
  if (!res.ok) throw new Error(`accounts:lookup failed: ${await res.text()}`);
  const data = await res.json();
  const user = data.users?.[0];
  if (!user?.email) return null;
  return { localId: user.localId as string, email: String(user.email).toLowerCase() };
}

/** Generates a password-reset action link WITHOUT Firebase sending its
 *  own email for it (that's what returnOobLink does) — we send our own
 *  branded email for it instead (see send-password-reset). The link's
 *  domain is whatever's configured as this template's "action URL" in
 *  Firebase Console > Authentication > Templates > Password reset — see
 *  EMAIL_SETUP.md step 5 for pointing that at the GitHub Pages page in
 *  docs/reset-password/. */
export async function generatePasswordResetLink(email: string): Promise<string> {
  const accessToken = await getIdentityToolkitAccessToken();
  const res = await fetch("https://identitytoolkit.googleapis.com/v1/accounts:sendOobCode", {
    method: "POST",
    headers: { Authorization: `Bearer ${accessToken}`, "Content-Type": "application/json" },
    body: JSON.stringify({ requestType: "PASSWORD_RESET", email, returnOobLink: true }),
  });
  if (!res.ok) throw new Error(`accounts:sendOobCode failed: ${await res.text()}`);
  const data = await res.json();
  return data.oobLink as string;
}

export { FIREBASE_PROJECT_ID };
