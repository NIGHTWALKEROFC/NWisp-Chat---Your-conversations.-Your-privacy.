import admin from "firebase-admin";

admin.initializeApp({
  credential: admin.credential.cert(JSON.parse(process.env.FIREBASE_SERVICE_ACCOUNT)),
});

const db = admin.firestore();
const now = admin.firestore.Timestamp.now();

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

async function main() {
  const expiredMessages = await deleteExpired(
    db.collectionGroup("messages").where("expiresAt", "<", now)
  );
  const expiredStories = await deleteExpired(
    db.collection("stories").where("expiresAt", "<", now)
  );
  console.log(`Deleted ${expiredMessages} expired messages, ${expiredStories} expired stories`);
}

main().then(() => process.exit(0)).catch((err) => { console.error(err); process.exit(1); });
