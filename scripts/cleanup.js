import admin from "firebase-admin";
import { createClient } from "@supabase/supabase-js";

admin.initializeApp({
  credential: admin.credential.cert(JSON.parse(process.env.FIREBASE_SERVICE_ACCOUNT)),
});

const db = admin.firestore();
const now = admin.firestore.Timestamp.now();

const supabase = createClient(process.env.SUPABASE_URL, process.env.SUPABASE_SERVICE_ROLE_KEY);

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
    const ttlMs = (row.ttl_hours ?? 24) * 60 * 60 * 1000;
    const graceMs = graceHours * 60 * 60 * 1000;
    return Date.now() - new Date(row.created_at).getTime() > ttlMs + graceMs;
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

async function main() {
  const expiredStories = await deleteExpired(
    db.collection("stories").where("expiresAt", "<", now)
  );
  console.log(`Deleted ${expiredStories} expired stories`);

  const relayResult = await cleanupMessageRelay();
  console.log(`Deleted ${relayResult.rows} stale message_relay rows (${relayResult.media} media files)`);
}

main().then(() => process.exit(0)).catch((err) => { console.error(err); process.exit(1); });
