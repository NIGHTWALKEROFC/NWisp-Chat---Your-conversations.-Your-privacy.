import { verifyAccessToken } from "../utils/jwt.js";
import { pool } from "../config/db.js";

export function initChatSocket(io) {
  io.use((socket, next) => {
    try {
      const token = socket.handshake.auth?.token;
      const payload = verifyAccessToken(token);
      socket.userId = payload.sub;
      next();
    } catch {
      next(new Error("unauthorized"));
    }
  });

  io.on("connection", (socket) => {
    socket.join(`user:${socket.userId}`);

    socket.on("message:send", async (payload, ack) => {
      const { conversationId, ciphertext, messageType, mediaUrl, replyToId } = payload;

      const member = await pool.query(
        "SELECT 1 FROM conversation_members WHERE conversation_id = $1 AND user_id = $2",
        [conversationId, socket.userId]
      );
      if (member.rows.length === 0) {
        return ack?.({ error: "Not a conversation member" });
      }

      const ttlHours = Number(process.env.MESSAGE_TTL_HOURS || 24);
      const result = await pool.query(
        `INSERT INTO messages (conversation_id, sender_id, ciphertext, message_type, media_url, reply_to_id, expires_at)
         VALUES ($1, $2, $3, $4, $5, $6, now() + ($7 || ' hours')::interval)
         RETURNING id, created_at`,
        [conversationId, socket.userId, ciphertext, messageType || "text", mediaUrl || null, replyToId || null, ttlHours]
      );

      const recipients = await pool.query(
        "SELECT user_id FROM conversation_members WHERE conversation_id = $1 AND user_id != $2",
        [conversationId, socket.userId]
      );

      const outgoing = {
        id: result.rows[0].id,
        conversationId,
        senderId: socket.userId,
        ciphertext,
        messageType: messageType || "text",
        mediaUrl,
        replyToId,
        createdAt: result.rows[0].created_at,
      };

      for (const row of recipients.rows) {
        io.to(`user:${row.user_id}`).emit("message:new", outgoing);
      }
      ack?.({ ok: true, id: result.rows[0].id });
    });

    socket.on("typing", ({ conversationId, isTyping }) => {
      socket.to(`conversation:${conversationId}`).emit("typing", { userId: socket.userId, isTyping });
    });

    socket.on("disconnect", () => {
      // presence cleanup handled via Redis TTL in a fuller implementation
    });
  });
}
