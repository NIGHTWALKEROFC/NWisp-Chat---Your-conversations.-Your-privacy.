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

// BUGFIX: the previous version verified the caller's Firebase ID token but
// never checked that `path` actually belonged to that caller. Any signed-in
// user could pass ANY bucket/path and get a valid signed *upload* URL for
// it - i.e. anyone could overwrite or vandalize another user's storage
// objects (avatars/stories/future chat media) just by knowing or guessing
// their uid + filename. Uploads are now hard-restricted to the caller's own
// path prefix ("<folder>/<uid>/...", the convention already used by
// StoryService and friends).
//
// Downloads are left permissive for now, matching the existing Firestore
// rule that lets any signed-in user read story documents (`allow read: if
// isSignedIn()`), i.e. this isn't a new hole - but it also does NOT check
// the blocked-users list yet. See "server-side enforcement of blocked-user
// story visibility" in the features list for the proper follow-up: a
// blocked user can currently still fetch a signed URL for the blocker's
// story media even though they're blocked.
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
      const { data, error } = await supabase.storage.from(bucket).createSignedUrl(path, 3600);
      if (error) throw error;
      return Response.json({ uid, signedUrl: data.signedUrl });
    } else {
      return new Response(JSON.stringify({ error: "Unknown mode" }), { status: 400 });
    }
  } catch (err) {
    return new Response(JSON.stringify({ error: String(err) }), { status: 401 });
  }
});
