// Server-side half of "you must update to keep using NWisp".
//
// WHY THIS EXISTS: a check that lives only inside the app can be cut out of a
// modified copy of the app. This one runs on the server, where it can't be
// edited. When the app's version is below the minimum you set in
// update/update.json, the server refuses to hand out the account role and
// media links, so an old (or modified-to-hide-the-update-screen) copy stops
// working no matter what its own code says.
//
// HONEST LIMIT: the version number is sent by the app, so someone who edits
// their copy can claim to be new. That is why this is one layer of several
// (signed update file, copy check inside the app, this) and not "unbreakable".
//
// SETUP: Supabase dashboard -> Edge Functions -> Secrets -> add
//   UPDATE_JSON_URL = the "raw" address of update/update.json in your GitHub repo
// Without that secret this gate does nothing (everything keeps working).
// If GitHub can't be reached the gate also lets the request through — a GitHub
// outage must never lock everyone out.

let cached: { min: number; at: number } | null = null;

async function minimumVersion(): Promise<number> {
  const url = Deno.env.get("UPDATE_JSON_URL");
  if (!url) return 0;
  if (cached && Date.now() - cached.at < 60_000) return cached.min;
  try {
    const res = await fetch(url, { headers: { "Cache-Control": "no-cache" } });
    if (!res.ok) return cached?.min ?? 0;
    const json = await res.json();
    const min = Number(json.minSupportedVersionCode ?? 0);
    cached = { min: Number.isFinite(min) ? min : 0, at: Date.now() };
    return cached.min;
  } catch (_) {
    return cached?.min ?? 0;
  }
}

/// Returns a ready-made 426 response if this app version is too old, else null.
export async function rejectIfOutdated(req: Request): Promise<Response | null> {
  const min = await minimumVersion();
  if (min <= 0) return null;
  const sent = Number(req.headers.get("x-app-version") ?? "0");
  // A request with no version at all comes from a very old build (before this
  // check existed) — treat it as outdated too.
  if (!Number.isFinite(sent) || sent < min) {
    return new Response(JSON.stringify({ error: "update_required", minVersion: min }), {
      status: 426,
      headers: { "Content-Type": "application/json" },
    });
  }
  return null;
}
