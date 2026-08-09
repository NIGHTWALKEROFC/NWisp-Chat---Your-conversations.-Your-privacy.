import bcrypt from "bcrypt";
import crypto from "crypto";
import { pool } from "../config/db.js";
import { signAccessToken, signRefreshToken, verifyRefreshToken } from "../utils/jwt.js";

const SALT_ROUNDS = 12;

export async function register(req, res) {
  const { username, email, phone, password, deviceKeys } = req.body;

  if (!username || !password || (!email && !phone)) {
    return res.status(400).json({ error: "username, password, and email or phone are required" });
  }
  if (password.length < 10) {
    return res.status(400).json({ error: "Password must be at least 10 characters" });
  }
  if (!deviceKeys || !deviceKeys.identityKey || !deviceKeys.signedPrekey) {
    return res.status(400).json({ error: "Device key bundle required (see Signal Protocol setup)" });
  }

  const client = await pool.connect();
  try {
    await client.query("BEGIN");

    const existing = await client.query(
      "SELECT id FROM users WHERE username = $1 OR email = $2 OR phone = $3",
      [username, email || null, phone || null]
    );
    if (existing.rows.length > 0) {
      await client.query("ROLLBACK");
      return res.status(409).json({ error: "Username, email, or phone already in use" });
    }

    const passwordHash = await bcrypt.hash(password, SALT_ROUNDS);

    const userResult = await client.query(
      `INSERT INTO users (username, email, phone, password_hash)
       VALUES ($1, $2, $3, $4) RETURNING id, username`,
      [username, email || null, phone || null, passwordHash]
    );
    const user = userResult.rows[0];

    const deviceKeyResult = await client.query(
      `INSERT INTO device_keys (user_id, device_id, identity_key, signed_prekey, signed_prekey_signature, registration_id)
       VALUES ($1, 1, $2, $3, $4, $5) RETURNING id`,
      [user.id, deviceKeys.identityKey, deviceKeys.signedPrekey, deviceKeys.signedPrekeySignature, deviceKeys.registrationId]
    );

    if (Array.isArray(deviceKeys.oneTimePrekeys)) {
      for (const otk of deviceKeys.oneTimePrekeys) {
        await client.query(
          `INSERT INTO one_time_prekeys (device_key_id, key_id, public_key) VALUES ($1, $2, $3)`,
          [deviceKeyResult.rows[0].id, otk.keyId, otk.publicKey]
        );
      }
    }

    await client.query("COMMIT");

    const accessToken = signAccessToken(user.id);
    const refreshToken = signRefreshToken(user.id);
    await storeRefreshToken(user.id, refreshToken, req.headers["user-agent"]);

    res.status(201).json({ user: { id: user.id, username: user.username }, accessToken, refreshToken });
  } catch (err) {
    await client.query("ROLLBACK");
    console.error(err);
    res.status(500).json({ error: "Registration failed" });
  } finally {
    client.release();
  }
}

export async function login(req, res) {
  const { identifier, password } = req.body; // identifier = username, email, or phone
  if (!identifier || !password) {
    return res.status(400).json({ error: "identifier and password required" });
  }

  const result = await pool.query(
    "SELECT id, username, password_hash FROM users WHERE username = $1 OR email = $1 OR phone = $1",
    [identifier]
  );
  const user = result.rows[0];

  // Constant-time-ish: always hash-compare even if user not found, to avoid user enumeration via timing
  const hashToCheck = user ? user.password_hash : "$2b$12$invalidinvalidinvalidinvalidinvalidinvalidinvalidinva";
  const valid = await bcrypt.compare(password, hashToCheck);

  if (!user || !valid) {
    return res.status(401).json({ error: "Invalid credentials" });
  }

  const accessToken = signAccessToken(user.id);
  const refreshToken = signRefreshToken(user.id);
  await storeRefreshToken(user.id, refreshToken, req.headers["user-agent"]);

  res.json({ user: { id: user.id, username: user.username }, accessToken, refreshToken });
}

export async function refresh(req, res) {
  const { refreshToken } = req.body;
  if (!refreshToken) return res.status(400).json({ error: "refreshToken required" });

  try {
    const payload = verifyRefreshToken(refreshToken);
    const tokenHash = crypto.createHash("sha256").update(refreshToken).digest("hex");

    const result = await pool.query(
      "SELECT id FROM refresh_tokens WHERE user_id = $1 AND token_hash = $2 AND revoked = false",
      [payload.sub, tokenHash]
    );
    if (result.rows.length === 0) {
      return res.status(401).json({ error: "Refresh token revoked or unknown" });
    }

    const accessToken = signAccessToken(payload.sub);
    res.json({ accessToken });
  } catch {
    res.status(401).json({ error: "Invalid refresh token" });
  }
}

export async function logout(req, res) {
  const { refreshToken } = req.body;
  if (refreshToken) {
    const tokenHash = crypto.createHash("sha256").update(refreshToken).digest("hex");
    await pool.query("UPDATE refresh_tokens SET revoked = true WHERE token_hash = $1", [tokenHash]);
  }
  res.json({ ok: true });
}

async function storeRefreshToken(userId, token, deviceInfo) {
  const tokenHash = crypto.createHash("sha256").update(token).digest("hex");
  await pool.query(
    "INSERT INTO refresh_tokens (user_id, token_hash, device_info) VALUES ($1, $2, $3)",
    [userId, tokenHash, deviceInfo || null]
  );
}
