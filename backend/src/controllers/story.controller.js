import { pool } from "../config/db.js";

export async function createStory(req, res) {
  const { mediaUrl, mediaType, circleId } = req.body;
  if (!mediaUrl || !mediaType) return res.status(400).json({ error: "mediaUrl and mediaType required" });

  const result = await pool.query(
    `INSERT INTO stories (user_id, media_url, media_type, visible_to_circle_id)
     VALUES ($1, $2, $3, $4) RETURNING id, expires_at`,
    [req.userId, mediaUrl, mediaType, circleId || null]
  );
  res.status(201).json(result.rows[0]);
}

export async function getFeedStories(req, res) {
  // Simplified: real version should filter by contacts + circle membership
  const result = await pool.query(
    `SELECT s.id, s.user_id, u.username, s.media_url, s.media_type, s.created_at, s.expires_at
     FROM stories s JOIN users u ON u.id = s.user_id
     WHERE s.expires_at > now()
     ORDER BY s.created_at DESC`
  );
  res.json({ stories: result.rows });
}

export async function viewStory(req, res) {
  const { storyId } = req.params;
  await pool.query(
    `INSERT INTO story_views (story_id, viewer_id) VALUES ($1, $2)
     ON CONFLICT DO NOTHING`,
    [storyId, req.userId]
  );
  res.json({ ok: true });
}

export async function deleteStory(req, res) {
  const { storyId } = req.params;
  const result = await pool.query(
    "DELETE FROM stories WHERE id = $1 AND user_id = $2 RETURNING id",
    [storyId, req.userId]
  );
  if (result.rows.length === 0) return res.status(404).json({ error: "Not found" });
  res.json({ ok: true });
}
