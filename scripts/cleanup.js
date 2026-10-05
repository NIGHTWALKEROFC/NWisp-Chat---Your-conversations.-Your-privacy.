import admin from "firebase-admin";
import { createClient } from "@supabase/supabase-js";

admin.initializeApp({
  credential: admin.credential.cert(JSON.parse(process.env.FIREBASE_SERVICE_ACCOUNT)),
});

const db = admin.firestore();
const now = admin.firestore.Timestamp.now();

// BUGFIX: a missing SUPABASE_URL/SUPABASE_SERVICE_ROLE_KEY secret used to
// throw immediately and fail the ENTIRE job — including the unrelated
// Firestore stories cleanup below, which has nothing to do with Supabase.
// Skip just the message_relay part with a clear warning instead, so the
// stories cleanup still runs even before those secrets are configured.
const supabase =
  process.env.SUPABASE_URL && process.env.SUPABASE_SERVICE_ROLE_KEY
    ? createClient(process.env.SUPABASE_URL, process.env.SUPABASE_SERVICE_ROLE_KEY)
    : null;

async function deleteExpired(query) {
  const snap = await query.get();
  const docs = snap.docs;
  const batchSize = 400;
  for (let i = 0; i < docs.length; i += batchSize) {
    const batch = db.batch();
    docs.slice(i, i + batchSize).forEach((doc) => batch.delete(doc.ref));
    await batch.commit();
  }
  return docs.length;
}

/// message_relay rows are meant to be picked up (decrypted, saved locally,
/// then deleted) by the recipient's own device within `ttl_hours` — but if
/// the recipient never comes back online, nothing was actually removing
/// them. This sweeps anything past its TTL (+ a grace window, in case a
/// device is just briefly offline) and — for image/video/voice messages —
/// deletes the matching encrypted blob from Storage too, so an
/// unresponsive recipient doesn't mean the sender's media sits on the
/// server forever.
async function cleanupMessageRelay() {
  const graceHours = 24;
  const cutoffIso = new Date(Date.now() - graceHours * 60 * 60 * 1000).toISOString();

  const { data: rows, error } = await supabase
    .from("message_relay")
    .select("id, media_path, created_at, ttl_hours")
    .lt("created_at", cutoffIso);
  if (error) throw error;

  const stale = (rows ?? []).filter((row) => {
    const ttlHours = row.ttl_hours ?? 0;
    const ageMs = Date.now() - new Date(row.created_at).getTime();
    if (ttlHours === 0) {
      // ttl_hours = 0 means the sender's chat is set to "never auto-
      // delete" — that shouldn't translate into "sweep it off the server
      // after 24 hours regardless." Give never-expiring, undelivered
      // messages a generous 90-day safety net instead, so a recipient who's
      // just been away for a while still gets their message, and only a
      // genuinely abandoned/deleted account's leftovers eventually get
      // cleaned up.
      const neverExpireSafetyCapMs = 90 * 24 * 60 * 60 * 1000;
      return ageMs > neverExpireSafetyCapMs;
    }
    const ttlMs = ttlHours * 60 * 60 * 1000;
    const graceMs = graceHours * 60 * 60 * 1000;
    return ageMs > ttlMs + graceMs;
  });
  if (stale.length === 0) return { rows: 0, media: 0 };

  const mediaPaths = stale.map((r) => r.media_path).filter(Boolean);
  if (mediaPaths.length > 0) {
    await supabase.storage.from("media").remove(mediaPaths);
  }

  const ids = stale.map((r) => r.id);
  const chunkSize = 200;
  for (let i = 0; i < ids.length; i += chunkSize) {
    const { error: delError } = await supabase.from("message_relay").delete().in("id", ids.slice(i, i + chunkSize));
    if (delError) throw delError;
  }

  return { rows: stale.length, media: mediaPaths.length };
}

/// Encrypted media files (photos, videos, voice, story files) that nothing
/// points at any more. They appear when someone's "auto-download" rule held a
/// file back and it was never opened, or a story's owner phone never got to
/// delete its temporary file. Anything older than `maxAgeDays` that no
/// message_relay row still references is removed, so storage can't pile up.
async function sweepOrphanMedia(maxAgeDays = 7) {
  const cutoff = Date.now() - maxAgeDays * 24 * 60 * 60 * 1000;

  const { data: rows, error } = await supabase.from("message_relay").select("media_path").not("media_path", "is", null);
  if (error) throw error;
  const referenced = new Set((rows ?? []).map((r) => r.media_path));

  const stale = [];
  // Folders look like "<kind>/<uid>/<file>"; list level by level.
  async function walk(prefix) {
    let offset = 0;
    for (;;) {
      const { data, error: listError } = await supabase.storage.from("media").list(prefix, { limit: 100, offset });
      if (listError) throw listError;
      if (!data || data.length === 0) break;
      for (const item of data) {
        const path = prefix ? `${prefix}/${item.name}` : item.name;
        if (item.id === null || item.id === undefined) {
          await walk(path); // a folder
        } else {
          const created = new Date(item.created_at ?? item.updated_at ?? Date.now()).getTime();
          if (created < cutoff && !referenced.has(path)) stale.push(path);
        }
      }
      if (data.length < 100) break;
      offset += 100;
    }
  }
  await walk("");

  const chunkSize = 100;
  for (let i = 0; i < stale.length; i += chunkSize) {
    await supabase.storage.from("media").remove(stale.slice(i, i + chunkSize));
  }
  return stale.length;
}

async function main() {
  const expiredStories = await deleteExpired(
    db.collection("stories").where("expiresAt", "<", now)
  );
  console.log(`Deleted ${expiredStories} expired stories`);

  if (!supabase) {
    console.warn(
      "Skipping message_relay cleanup: SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY " +
      "are not set as repo secrets yet (see the setup notes)."
    );
    return;
  }
  try {
    const relayResult = await cleanupMessageRelay();
    console.log(`Deleted ${relayResult.rows} stale message_relay rows (${relayResult.media} media files)`);
  } catch (err) {
    // BUGFIX: any Supabase-side error here (e.g. a misconfigured
    // SUPABASE_URL producing a PGRST125 "Invalid path" response) used to
    // crash the entire job with exit code 1. This cleanup is server
    // hygiene for messages that were never delivered — it has nothing to
    // do with a user's own on-device chat history — so a failure here
    // should never fail the whole scheduled job, just get logged for
    // whoever's watching the Action's output.
    console.warn("message_relay cleanup failed (will retry on the next scheduled run):", err);
  }
  try {
    const removed = await sweepOrphanMedia();
    console.log(`Removed ${removed} orphaned media files`);
  } catch (err) {
    console.warn("orphan media sweep failed (will retry on the next scheduled run):", err);
  }
}

main().then(() => process.exit(0)).catch((err) => { console.error(err); process.exit(1); });
