import { pool } from "../config/db.js";

// Fetch undelivered / recent messages for a conversation (ciphertext only)
export async function getMessages(req, res) {
  const { conversationId } = req.params;
  const member = await pool.query(
    "SELECT 1 FROM conversation_members WHERE conversation_id = $1 AND user_id = $2",
    [conversationId, req.userId]
  );
  if (member.rows.length === 0) return res.status(403).json({ error: "Not a member of this conversation" });

  const result = await pool.query(
    `SELECT id, sender_id, ciphertext, message_type, media_url, reply_to_id, created_at
     FROM messages WHERE conversation_id = $1 AND expires_at > now()
     ORDER BY created_at ASC`,
    [conversationId]
  );
  res.json({ messages: result.rows });
}

export async function markDelivered(req, res) {
  const { messageId } = req.params;
  await pool.query(
    `UPDATE messages SET delivered_to = array_append(delivered_to, $1)
     WHERE id = $2 AND NOT ($1 = ANY(delivered_to))`,
    [req.userId, messageId]
  );
  res.json({ ok: true });
}

export async function markRead(req, res) {
  const { messageId } = req.params;
  await pool.query(
    `UPDATE messages SET read_by = array_append(read_by, $1)
     WHERE id = $2 AND NOT ($1 = ANY(read_by))`,
    [req.userId, messageId]
  );
  res.json({ ok: true });
}
