import cron from "node-cron";
import { pool } from "../config/db.js";

export function startCleanupJob() {
  // Runs every 15 minutes
  cron.schedule("*/15 * * * *", async () => {
    try {
      const messages = await pool.query("DELETE FROM messages WHERE expires_at < now()");
      const stories = await pool.query("DELETE FROM stories WHERE expires_at < now()");
      const otks = await pool.query(
        "DELETE FROM refresh_tokens WHERE created_at < now() - interval '31 days'"
      );
      console.log(`Cleanup: ${messages.rowCount} messages, ${stories.rowCount} stories, ${otks.rowCount} old tokens removed`);
    } catch (err) {
      console.error("Cleanup job failed", err);
    }
  });
}
