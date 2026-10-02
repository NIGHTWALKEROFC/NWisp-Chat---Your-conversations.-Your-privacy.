import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import * as jose from "https://esm.sh/jose@5";

// Feature: NWisp Bots — the app-facing half (create / edit / delete bots,
// new API key, and a person chatting with a bot). The bot-owner-facing half
// that bots call from wherever they are hosted is nwisp-bot-api.
//
// Who is asking is proven by their Firebase ID token (same method as the
// other functions). Needs the secrets already in your project:
// FIREBASE_PROJECT_ID. SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY are
// provided to every Edge Function automatically — nothing to add.
//
// Turn OFF "Enforce JWT verification" for this function (the app sends a
// Firebase token, not a Supabase one — this function checks it itself).

const FIREBASE_PROJECT_ID = Deno.env.get("FIREBASE_PROJECT_ID")!;
// Comma-separated Firebase user ids allowed to use the admin tools (reports,
// suspend, ban). Add the secret BOT_ADMIN_UIDS in Supabase. Empty = nobody.
const ADMIN_UIDS = (Deno.env.get("BOT_ADMIN_UIDS") ?? "").split(",").map((x) => x.trim()).filter(Boolean);
// Used to check group membership in Firestore (already set for send-push).
const SA_EMAIL = Deno.env.get("FIREBASE_SERVICE_ACCOUNT_EMAIL") ?? "";
const SA_KEY = (Deno.env.get("FIREBASE_SERVICE_ACCOUNT_PRIVATE_KEY") ?? "").replace(/\\n/g, "\n");
const FIRESTORE_BASE = `https://firestore.googleapis.com/v1/projects/${FIREBASE_PROJECT_ID}/databases/(default)/documents`;
const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
  auth: { persistSession: false },
});
const JWKS = jose.createRemoteJWKSet(
  new URL("https://www.googleapis.com/service_accounts/v1/jwk/securetoken@system.gserviceaccount.com"),
);
const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, content-type",
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...CORS, "Content-Type": "application/json" } });

// ------------------------------------------------------------------ rules
// Every switch starts OFF. The owner turns on what the bot is allowed to do;
// both this function and the Bot API enforce them.
const RULE_KEYS = [
  "public",         // anyone can start the bot (off = only its owner, for testing)
  "shareUsername",  // the bot sees the person's NWisp username (off = anonymous)
  "buttons",        // bot messages may carry buttons
  "media",          // bot may send photos (by link)
  "formatting",     // **bold**, _italic_ and `code` in bot messages
  "editDelete",     // bot may edit or delete its own messages
  "typing",         // bot may show "typing…"
  "webhook",        // updates may be pushed to the owner's server (otherwise getUpdates only)
  "commandsMenu",   // show the "/" command list in the chat
  "longMessages",   // up to 4000 characters per message (off = 1000)
  "groups",         // the bot may be added to groups
  "seeAllMessages", // in groups: see every message (off = only /commands, @mentions and replies to the bot)
] as const;

function cleanRules(input: any): Record<string, boolean> {
  const out: Record<string, boolean> = {};
  for (const k of RULE_KEYS) out[k] = input?.[k] === true;
  return out;
}

const RESERVED = new Set([
  "nwisp_bot", "official_bot", "admin_bot", "support_bot", "security_bot", "help_bot",
  "botfather_bot", "system_bot", "moderator_bot", "staff_bot", "team_bot", "nwispchat_bot",
]);

function checkUsername(u: string): string | null {
  if (typeof u !== "string") return "Invalid username.";
  if (!u.endsWith("_bot")) return "A bot username must end with _bot.";
  if (u.length < 7 || u.length > 32) return "Use 7–32 characters including _bot.";
  if (!/^[a-z0-9]([a-z0-9_]*[a-z0-9])?_bot$/.test(u)) {
    return "Only lowercase letters, numbers and underscores. It must start with a letter or number.";
  }
  if (u.endsWith("__bot")) return "Use a single underscore before bot (a double underscore is for normal accounts).";
  if (RESERVED.has(u)) return "That name is reserved.";
  return null;
}

async function sha256Hex(text: string): Promise<string> {
  const buf = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text));
  return [...new Uint8Array(buf)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

function randomString(len: number): string {
  const chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789";
  const bytes = crypto.getRandomValues(new Uint8Array(len));
  return [...bytes].map((b) => chars[b % chars.length]).join("");
}

async function verifyIdToken(req: Request): Promise<string> {
  const idToken = (req.headers.get("Authorization") || "").replace("Bearer ", "");
  if (!idToken) throw new Error("Missing Authorization header");
  const { payload } = await jose.jwtVerify(idToken, JWKS, {
    issuer: `https://securetoken.google.com/${FIREBASE_PROJECT_ID}`,
    audience: FIREBASE_PROJECT_ID,
  });
  return payload.sub as string;
}

function publicBot(b: any, uid: string, forOwnerEditing = false) {
  const owner = b.owner_uid === uid;
  return {
    username: b.username,
    name: b.name,
    description: b.description,
    photo_data: b.photo_data ?? null,
    rules: b.rules,
    commands: (b.rules?.commandsMenu || (owner && forOwnerEditing)) ? (b.commands ?? []) : [],
    isOwner: owner,
    status: owner ? (b.status ?? "active") : "active",
    statusReason: owner ? (b.status_reason ?? null) : null,
  };
}

class HttpError extends Error {
  status: number;
  constructor(status: number, message: string) { super(message); this.status = status; }
}

// ---------------------------------------------------------------- Firestore
let cachedGoogle: { token: string; expiresAt: number } | null = null;
async function googleToken(): Promise<string> {
  if (cachedGoogle && cachedGoogle.expiresAt > Date.now() + 30_000) return cachedGoogle.token;
  const key = await jose.importPKCS8(SA_KEY, "RS256");
  const now = Math.floor(Date.now() / 1000);
  const assertion = await new jose.SignJWT({ scope: "https://www.googleapis.com/auth/datastore" })
    .setProtectedHeader({ alg: "RS256" }).setIssuer(SA_EMAIL).setSubject(SA_EMAIL)
    .setAudience("https://oauth2.googleapis.com/token").setIssuedAt(now).setExpirationTime(now + 3600).sign(key);
  const res = await fetch("https://oauth2.googleapis.com/token", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({ grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer", assertion }),
  });
  if (!res.ok) throw new Error("Couldn't reach Firebase");
  const d = await res.json();
  cachedGoogle = { token: d.access_token, expiresAt: Date.now() + d.expires_in * 1000 };
  return d.access_token;
}
function fsValue(v: any): any {
  if (v == null) return null;
  if ("stringValue" in v) return v.stringValue;
  if ("booleanValue" in v) return v.booleanValue;
  if ("arrayValue" in v) return (v.arrayValue.values ?? []).map(fsValue);
  return null;
}
async function fsGet(path: string): Promise<Record<string, any> | null> {
  const res = await fetch(`${FIRESTORE_BASE}/${path}`, { headers: { Authorization: `Bearer ${await googleToken()}` } });
  if (res.status === 404) return null;
  if (!res.ok) throw new Error("Couldn't read Firebase");
  const d = await res.json();
  const out: Record<string, any> = {};
  for (const k in d.fields ?? {}) out[k] = fsValue(d.fields[k]);
  return out;
}
const groupCache = new Map<string, { at: number; data: any }>();
/** A group the person belongs to (members/admins are read live from Firestore, cached 60 s). */
async function requireGroup(uid: string, groupId: string) {
  if (!/^[A-Za-z0-9_-]{6,80}$/.test(groupId)) throw new HttpError(400, "Bad group.");
  let c = groupCache.get(groupId);
  if (!c || Date.now() - c.at > 60_000) {
    const data = await fsGet(`groups/${groupId}`);
    c = { at: Date.now(), data };
    groupCache.set(groupId, c);
  }
  const g = c.data;
  if (!g) throw new HttpError(404, "Group not found.");
  const members: string[] = g.members ?? [];
  if (!members.includes(uid)) throw new HttpError(403, "You're not in this group.");
  return { name: String(g.name ?? "Group"), isAdmin: (g.admins ?? []).includes(uid) };
}
const nameCache = new Map<string, string>();
async function usernameOf(uid: string): Promise<string> {
  const hit = nameCache.get(uid);
  if (hit) return hit;
  try {
    const d = await fsGet(`users/${uid}`);
    const n = String(d?.username ?? "member").slice(0, 40);
    nameCache.set(uid, n);
    return n;
  } catch (_) { return "member"; }
}

const REPORT_REASONS = new Set(["spam", "scam", "abuse", "illegal", "impersonation", "other"]);
const AUTO_SUSPEND_AT = 5; // different people who must report a bot before it is suspended automatically

function sanitizeCommands(list: any): { command: string; description: string }[] | null {
  if (!Array.isArray(list) || list.length > 30) return null;
  return list
    .map((c: any) => ({ command: String(c?.command ?? "").toLowerCase().replace(/^\//, "").slice(0, 32), description: String(c?.description ?? "").slice(0, 100) }))
    .filter((c) => /^[a-z0-9_]{1,32}$/.test(c.command));
}

async function pushWebhook(bot: any, update: unknown) {
  if (!bot.rules?.webhook || !bot.webhook_url) return;
  fetch(bot.webhook_url, {
    method: "POST",
    headers: { "Content-Type": "application/json", "X-NWisp-Bot-Api-Secret-Token": bot.webhook_secret ?? "" },
    body: JSON.stringify(update),
    signal: AbortSignal.timeout(5000),
  }).then(async () => {
    const id = (update as any).update_id;
    await db.from("bots").update({ update_cursor: id }).eq("username", bot.username).lt("update_cursor", id);
  }).catch(() => {});
}

function validPhoto(p: unknown): boolean {
  return typeof p === "string" && p.startsWith("data:image/") && p.length <= 90_000;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  try {
    const uid = await verifyIdToken(req);
    const body = await req.json();
    const action = String(body.action ?? "");

    // Light housekeeping: now and then drop messages older than 7 days so the
    // free database never fills up.
    if (Math.random() < 0.02) {
      const cutoff = new Date(Date.now() - 7 * 86400_000).toISOString();
      await db.from("bot_messages").delete().lt("created_at", cutoff);
    }

    switch (action) {
      // ------------------------------------------------------ username
      case "check_username": {
        const u = String(body.username ?? "").toLowerCase();
        const problem = checkUsername(u);
        if (problem) return json({ valid: false, available: false, reason: problem });
        const { data } = await db.from("bots").select("username").eq("username", u).maybeSingle();
        return json({ valid: true, available: !data });
      }

      // ------------------------------------------------------ create
      case "create_bot": {
        const username = String(body.username ?? "").toLowerCase();
        const problem = checkUsername(username);
        if (problem) return json({ error: problem }, 400);
        const name = String(body.name ?? "").trim();
        if (name.length < 1 || name.length > 64) return json({ error: "Give the bot a name (1–64 characters)." }, 400);
        const description = String(body.description ?? "").trim().slice(0, 300);
        const photo = body.photo_data ?? null;
        if (photo !== null && !validPhoto(photo)) return json({ error: "That picture is too large." }, 400);
        const { count } = await db.from("bots").select("username", { count: "exact", head: true }).eq("owner_uid", uid);
        if ((count ?? 0) >= 10) return json({ error: "You can have up to 10 bots." }, 400);
        const secret = randomString(40);
        const { data, error } = await db
          .from("bots")
          .insert({
            username, owner_uid: uid, name, description, photo_data: photo,
            rules: cleanRules(body.rules), token_hash: await sha256Hex(secret),
          })
          .select()
          .single();
        if (error) {
          if (String(error.code) === "23505") return json({ error: "That username is already taken." }, 409);
          return json({ error: "Couldn't create the bot." }, 500);
        }
        return json({ bot: publicBot(data, uid), token: `${data.bot_id}:${secret}` });
      }

      // ------------------------------------------------------ mine
      case "list_mine": {
        const { data } = await db.from("bots").select("*").eq("owner_uid", uid).order("created_at", { ascending: false });
        return json({ bots: (data ?? []).map((b) => ({ ...publicBot(b, uid, true), webhook: !!b.webhook_url })) });
      }

      // ------------------------------------------------------ update
      case "update_bot": {
        const username = String(body.username ?? "").toLowerCase();
        const { data: bot } = await db.from("bots").select("*").eq("username", username).maybeSingle();
        if (!bot || bot.owner_uid !== uid) return json({ error: "Bot not found." }, 404);
        const patch: Record<string, unknown> = {};
        if (body.name !== undefined) {
          const n = String(body.name).trim();
          if (n.length < 1 || n.length > 64) return json({ error: "Name must be 1–64 characters." }, 400);
          patch.name = n;
        }
        if (body.description !== undefined) patch.description = String(body.description).trim().slice(0, 300);
        if (body.photo_data !== undefined) {
          if (body.photo_data !== null && !validPhoto(body.photo_data)) return json({ error: "That picture is too large." }, 400);
          patch.photo_data = body.photo_data;
        }
        if (body.rules !== undefined) {
          patch.rules = cleanRules(body.rules);
          // Turning webhooks off also clears the address.
          if (!(patch.rules as any).webhook) { patch.webhook_url = null; patch.webhook_secret = null; }
        }
        if (Object.keys(patch).length === 0) return json({ bot: publicBot(bot, uid) });
        const { data, error } = await db.from("bots").update(patch).eq("username", username).select().single();
        if (error) return json({ error: "Couldn't save." }, 500);
        return json({ bot: publicBot(data, uid) });
      }

      // ------------------------------------------------------ delete
      case "delete_bot": {
        const username = String(body.username ?? "").toLowerCase();
        const { data: bot } = await db.from("bots").select("owner_uid").eq("username", username).maybeSingle();
        if (!bot || bot.owner_uid !== uid) return json({ error: "Bot not found." }, 404);
        await db.from("bots").delete().eq("username", username); // messages and users go with it
        return json({ ok: true });
      }

      // ------------------------------------------------------ new key
      case "regenerate_token": {
        const username = String(body.username ?? "").toLowerCase();
        const { data: bot } = await db.from("bots").select("owner_uid, bot_id").eq("username", username).maybeSingle();
        if (!bot || bot.owner_uid !== uid) return json({ error: "Bot not found." }, 404);
        const secret = randomString(40);
        await db.from("bots").update({ token_hash: await sha256Hex(secret) }).eq("username", username);
        // The old key stops working immediately.
        return json({ token: `${bot.bot_id}:${secret}` });
      }

      // ------------------------------------------------------ public info
      case "get_bot": {
        const username = String(body.username ?? "").toLowerCase();
        const { data: bot } = await db.from("bots").select("*").eq("username", username).maybeSingle();
        if (!bot) return json({ bot: null, reason: "not_found" });
        if (bot.status !== "active" && bot.owner_uid !== uid) return json({ bot: null, reason: "suspended" });
        if (!bot.rules?.public && bot.owner_uid !== uid) return json({ bot: null, reason: "private" });
        return json({ bot: publicBot(bot, uid) });
      }

      // ------------------------------------------------------ chats I started
      case "my_chats": {
        const { data: started } = await db.from("bot_users").select("bot, blocked, started_at").eq("user_uid", uid)
          .order("started_at", { ascending: false }).limit(50);
        const names = (started ?? []).map((s) => s.bot);
        if (names.length === 0) return json({ bots: [] });
        const { data: bots } = await db.from("bots").select("*").in("username", names);
        const byName = new Map((bots ?? []).map((b) => [b.username, b]));
        return json({
          bots: (started ?? []).filter((s) => byName.has(s.bot) && byName.get(s.bot).status === "active").map((s) => ({
            ...publicBot(byName.get(s.bot), uid), blocked: s.blocked,
          })),
        });
      }

      // ------------------------------------------------------ send to bot
      case "send":
      case "callback": {
        const username = String(body.username ?? "").toLowerCase();
        const { data: bot } = await db.from("bots").select("*").eq("username", username).maybeSingle();
        if (!bot) return json({ error: "This bot doesn't exist any more." }, 404);
        if (bot.status !== "active") return json({ error: "This bot has been suspended." }, 403);
        if (!bot.rules?.public && bot.owner_uid !== uid) return json({ error: "This bot isn't open to everyone yet." }, 403);

        const { data: existing } = await db.from("bot_users").select("blocked, owner_blocked, chat_id").eq("bot", username).eq("user_uid", uid).maybeSingle();
        if (existing?.blocked) return json({ error: "You blocked this bot. Unblock it first." }, 403);
        if (existing?.owner_blocked) return json({ error: "The owner of this bot has blocked you." }, 403);

        // Soft rate limit: 20 messages a minute from one person to one bot.
        const since = new Date(Date.now() - 60_000).toISOString();
        const { count: recent } = await db.from("bot_messages").select("id", { count: "exact", head: true })
          .eq("bot", username).eq("user_uid", uid).eq("direction", "in").is("group_id", null).gte("created_at", since);
        if ((recent ?? 0) >= 20) return json({ error: "Slow down a little." }, 429);

        let kind = "text";
        let text = "";
        const extra: Record<string, unknown> = {};
        if (action === "callback") {
          if (!bot.rules?.buttons) return json({ error: "Buttons are turned off for this bot." }, 403);
          kind = "callback";
          extra.data = String(body.data ?? "").slice(0, 64);
          extra.messageId = Number(body.messageId ?? 0);
        } else {
          text = String(body.text ?? "").trim();
          if (text.length === 0) return json({ error: "Empty message." }, 400);
          if (text.length > 4000) return json({ error: "Too long." }, 400);
        }

        // First time: this is "starting" the bot.
        let chatId = existing?.chat_id;
        if (!existing) {
          const { data: created } = await db.from("bot_users").insert({ bot: username, user_uid: uid }).select("chat_id").single();
          chatId = created?.chat_id;
        }
        if (bot.rules?.shareUsername) {
          const nm = String(body.fromName ?? "").slice(0, 40);
          if (nm) extra.username = nm;
        }
        const { data: row, error } = await db.from("bot_messages")
          .insert({ bot: username, user_uid: uid, direction: "in", kind, body: text, extra })
          .select().single();
        if (error) return json({ error: "Couldn't send." }, 500);

        // Push to the owner's server if they use a webhook.
        {
          const from: Record<string, unknown> = { id: chatId, is_bot: false, first_name: "User" };
          if (extra.username) { from.username = extra.username; from.first_name = extra.username; }
          await pushWebhook(bot, kind === "callback"
            ? { update_id: row.id, callback_query: { id: String(row.id), from, data: extra.data, message: { message_id: extra.messageId, chat: { id: chatId } } } }
            : { update_id: row.id, message: { message_id: row.id, from, chat: { id: chatId, type: "private" }, date: Math.floor(Date.now() / 1000), text } });
        }
        return json({ id: row.id, created_at: row.created_at });
      }

      // ------------------------------------------------------ read the chat
      // history = true loads the recent history. Otherwise only messages after
      // afterId come back, plus anything edited or deleted since `since` (the
      // server time of the last poll).
      case "poll": {
        const username = String(body.username ?? "").toLowerCase();
        const history = body.history === true;
        const afterId = Number(body.afterId ?? 0);
        const since = body.since ? String(body.since) : null;
        const waitMs = Math.min(Math.max(Number(body.waitSeconds ?? 0), 0), 15) * 1000;
        const started = Date.now();
        while (true) {
          let q = db.from("bot_messages").select("id, direction, kind, body, extra, edited, deleted, created_at, updated_at")
            .eq("bot", username).eq("user_uid", uid).is("group_id", null);
          if (history) {
            q = q.order("id", { ascending: false }).limit(80);
          } else {
            q = since ? q.or(`id.gt.${afterId},updated_at.gt.${since}`) : q.gt("id", afterId);
            q = q.order("id", { ascending: true }).limit(100);
          }
          const { data } = await q;
          const serverTime = new Date().toISOString();
          const { data: bu } = await db.from("bot_users").select("typing_until").eq("bot", username).eq("user_uid", uid).maybeSingle();
          const typing = !!bu?.typing_until && new Date(bu.typing_until).getTime() > Date.now();
          const rows = history ? (data ?? []).reverse() : (data ?? []);
          if (rows.length > 0 || typing || Date.now() - started >= waitMs) {
            return json({ messages: rows, typing, serverTime });
          }
          await new Promise((r) => setTimeout(r, 1500));
        }
      }

      // ------------------------------------------------------ block / unblock
      case "block": {
        const username = String(body.username ?? "").toLowerCase();
        await db.from("bot_users").update({ blocked: body.blocked === true }).eq("bot", username).eq("user_uid", uid);
        return json({ ok: true });
      }

      // ------------------------------------------------------ clear my chat
      case "clear_chat": {
        const username = String(body.username ?? "").toLowerCase();
        await db.from("bot_messages").delete().eq("bot", username).eq("user_uid", uid).is("group_id", null);
        return json({ ok: true });
      }

      // ====================================================== moderation
      case "whoami":
        return json({ isAdmin: ADMIN_UIDS.includes(uid) });

      case "report_bot": {
        const username = String(body.username ?? "").toLowerCase();
        const reason = String(body.reason ?? "other");
        if (!REPORT_REASONS.has(reason)) return json({ error: "Pick a reason." }, 400);
        const { data: bot } = await db.from("bots").select("username, owner_uid, status").eq("username", username).maybeSingle();
        if (!bot) return json({ error: "Bot not found." }, 404);
        if (bot.owner_uid === uid) return json({ error: "You can't report your own bot." }, 400);
        await db.from("bot_reports").upsert(
          { bot: username, reporter_uid: uid, reason, details: String(body.details ?? "").slice(0, 500), dismissed: false },
          { onConflict: "bot,reporter_uid" },
        );
        const { count } = await db.from("bot_reports").select("id", { count: "exact", head: true }).eq("bot", username).eq("dismissed", false);
        if ((count ?? 0) >= AUTO_SUSPEND_AT && bot.status === "active") {
          await db.from("bots").update({ status: "suspended", status_reason: "Suspended automatically after several reports. It is being reviewed." }).eq("username", username);
        }
        return json({ ok: true });
      }

      case "admin_reports": {
        if (!ADMIN_UIDS.includes(uid)) return json({ error: "Not allowed." }, 403);
        const { data: reports } = await db.from("bot_reports").select("bot, reason, details, created_at").eq("dismissed", false)
          .order("created_at", { ascending: false }).limit(500);
        const groups = new Map<string, { reasons: Record<string, number>; details: string[]; count: number; last: string }>();
        for (const r of reports ?? []) {
          const g = groups.get(r.bot) ?? { reasons: {}, details: [], count: 0, last: r.created_at };
          g.count++;
          g.reasons[r.reason] = (g.reasons[r.reason] ?? 0) + 1;
          if (r.details && g.details.length < 5) g.details.push(String(r.details));
          groups.set(r.bot, g);
        }
        const names = [...groups.keys()];
        const { data: bots } = names.length ? await db.from("bots").select("username, name, owner_uid, status, status_reason").in("username", names) : { data: [] };
        return json({
          items: (bots ?? []).map((b) => ({ ...b, ...groups.get(b.username) })).sort((a: any, b: any) => b.count - a.count),
        });
      }

      case "admin_set_status": {
        if (!ADMIN_UIDS.includes(uid)) return json({ error: "Not allowed." }, 403);
        const username = String(body.username ?? "").toLowerCase();
        const status = String(body.status ?? "");
        if (!["active", "suspended", "banned"].includes(status)) return json({ error: "Bad status." }, 400);
        const reason = String(body.reason ?? "").slice(0, 200);
        await db.from("bots").update({ status, status_reason: status === "active" ? null : (reason || "Removed by NWisp moderators.") }).eq("username", username);
        if (status === "active") await db.from("bot_reports").update({ dismissed: true }).eq("bot", username);
        return json({ ok: true });
      }

      case "admin_dismiss": {
        if (!ADMIN_UIDS.includes(uid)) return json({ error: "Not allowed." }, 403);
        await db.from("bot_reports").update({ dismissed: true }).eq("bot", String(body.username ?? "").toLowerCase());
        return json({ ok: true });
      }

      // ====================================================== command menu
      case "set_commands": {
        const username = String(body.username ?? "").toLowerCase();
        const { data: bot } = await db.from("bots").select("owner_uid").eq("username", username).maybeSingle();
        if (!bot || bot.owner_uid !== uid) return json({ error: "Bot not found." }, 404);
        const cleaned = sanitizeCommands(body.commands);
        if (!cleaned) return json({ error: "Up to 30 commands." }, 400);
        await db.from("bots").update({ commands: cleaned }).eq("username", username);
        return json({ ok: true, commands: cleaned });
      }

      // ====================================================== bots in groups
      case "group_list_bots": {
        const groupId = String(body.groupId ?? "");
        await requireGroup(uid, groupId);
        const { data: links } = await db.from("bot_groups").select("bot").eq("group_id", groupId);
        const names = (links ?? []).map((l) => l.bot);
        if (!names.length) return json({ bots: [] });
        const { data: bots } = await db.from("bots").select("*").in("username", names);
        return json({ bots: (bots ?? []).filter((b) => b.status === "active").map((b) => publicBot(b, uid)) });
      }

      case "group_add_bot": {
        const groupId = String(body.groupId ?? "");
        const g = await requireGroup(uid, groupId);
        if (!g.isAdmin) return json({ error: "Only group admins can add a bot." }, 403);
        const username = String(body.username ?? "").toLowerCase().replace(/^@/, "");
        const { data: bot } = await db.from("bots").select("*").eq("username", username).maybeSingle();
        if (!bot || bot.status !== "active") return json({ error: "No such bot." }, 404);
        if (!bot.rules?.groups) return json({ error: "This bot's owner hasn't allowed it in groups." }, 403);
        if (!bot.rules?.public && bot.owner_uid !== uid) return json({ error: "This bot isn't open to everyone yet." }, 403);
        const { count } = await db.from("bot_groups").select("bot", { count: "exact", head: true }).eq("group_id", groupId);
        if ((count ?? 0) >= 3) return json({ error: "A group can have up to 3 bots." }, 400);
        const { error } = await db.from("bot_groups").insert({ bot: username, group_id: groupId, group_name: g.name, added_by: uid });
        if (error && String(error.code) !== "23505") return json({ error: "Couldn't add the bot." }, 500);
        await db.from("bot_messages").insert({
          bot: username, user_uid: uid, group_id: groupId, direction: "in", kind: "system", visible_to_bot: false,
          body: `${await usernameOf(uid)} added ${bot.name} (@${username}) to this group`,
        });
        return json({ ok: true });
      }

      case "group_remove_bot": {
        const groupId = String(body.groupId ?? "");
        const g = await requireGroup(uid, groupId);
        const username = String(body.username ?? "").toLowerCase();
        const { data: bot } = await db.from("bots").select("owner_uid, name").eq("username", username).maybeSingle();
        if (!g.isAdmin && bot?.owner_uid !== uid) return json({ error: "Only group admins can remove a bot." }, 403);
        await db.from("bot_groups").delete().eq("bot", username).eq("group_id", groupId);
        await db.from("bot_messages").insert({
          bot: username, user_uid: uid, group_id: groupId, direction: "in", kind: "system", visible_to_bot: false,
          body: `${await usernameOf(uid)} removed @${username} from this group`,
        }).then(() => {}, () => {});
        return json({ ok: true });
      }

      case "group_send": {
        const groupId = String(body.groupId ?? "");
        await requireGroup(uid, groupId);
        const username = String(body.username ?? "").toLowerCase();
        const { data: bot } = await db.from("bots").select("*").eq("username", username).maybeSingle();
        const { data: link } = await db.from("bot_groups").select("chat_id").eq("bot", username).eq("group_id", groupId).maybeSingle();
        if (!bot || !link) return json({ error: "This bot isn't in the group." }, 404);
        if (bot.status !== "active") return json({ error: "This bot has been suspended." }, 403);
        const text = String(body.text ?? "").trim();
        if (!text) return json({ error: "Empty message." }, 400);
        if (text.length > 4000) return json({ error: "Too long." }, 400);

        const since = new Date(Date.now() - 60_000).toISOString();
        const { count: recent } = await db.from("bot_messages").select("id", { count: "exact", head: true })
          .eq("bot", username).eq("group_id", groupId).eq("user_uid", uid).eq("direction", "in").gte("created_at", since);
        if ((recent ?? 0) >= 20) return json({ error: "Slow down a little." }, 429);

        const { data: bu } = await db.from("bot_users").select("owner_blocked, chat_id").eq("bot", username).eq("user_uid", uid).maybeSingle();
        if (bu?.owner_blocked) return json({ error: "The owner of this bot has blocked you." }, 403);

        // What the bot is allowed to see in a group (like Telegram's privacy mode):
        // commands, @mentions of the bot, and replies to the bot — or everything,
        // if its owner switched "seeAllMessages" on.
        const replyTo = Number(body.replyTo ?? 0);
        let replyToBot = false;
        if (replyTo > 0) {
          const { data: orig } = await db.from("bot_messages").select("direction").eq("id", replyTo).eq("bot", username).eq("group_id", groupId).maybeSingle();
          replyToBot = orig?.direction === "out";
        }
        const mention = new RegExp(`@${username}\\b`, "i").test(text);
        const visible = !!bot.rules?.seeAllMessages || text.startsWith("/") || mention || replyToBot;

        const senderName = await usernameOf(uid);
        const extra: Record<string, unknown> = { name: senderName };
        if (replyTo > 0) extra.replyTo = replyTo;
        const { data: row, error } = await db.from("bot_messages")
          .insert({ bot: username, user_uid: uid, group_id: groupId, direction: "in", kind: "text", body: text, extra, visible_to_bot: visible })
          .select().single();
        if (error) return json({ error: "Couldn't send." }, 500);

        if (visible) {
          let chatId = bu?.chat_id;
          if (!bu) {
            const { data: created } = await db.from("bot_users").insert({ bot: username, user_uid: uid, started_private: false }).select("chat_id").single();
            chatId = created?.chat_id;
          }
          const from: Record<string, unknown> = { id: chatId, is_bot: false, first_name: "User" };
          if (bot.rules?.shareUsername) { from.username = senderName; from.first_name = senderName; }
          await pushWebhook(bot, {
            update_id: row.id,
            message: { message_id: row.id, from, chat: { id: -link.chat_id, type: "group", title: (await requireGroup(uid, groupId)).name }, date: Math.floor(Date.now() / 1000), text },
          });
        }
        return json({ id: row.id, created_at: row.created_at, seenByBot: visible });
      }

      case "group_poll": {
        const groupId = String(body.groupId ?? "");
        await requireGroup(uid, groupId);
        const username = String(body.username ?? "").toLowerCase();
        const history = body.history === true;
        const afterId = Number(body.afterId ?? 0);
        const since = body.since ? String(body.since) : null;
        const waitMs = Math.min(Math.max(Number(body.waitSeconds ?? 0), 0), 15) * 1000;
        const started = Date.now();
        while (true) {
          let q = db.from("bot_messages").select("id, user_uid, direction, kind, body, extra, edited, deleted, visible_to_bot, created_at, updated_at")
            .eq("bot", username).eq("group_id", groupId);
          if (history) q = q.order("id", { ascending: false }).limit(80);
          else {
            q = since ? q.or(`id.gt.${afterId},updated_at.gt.${since}`) : q.gt("id", afterId);
            q = q.order("id", { ascending: true }).limit(100);
          }
          const { data } = await q;
          const serverTime = new Date().toISOString();
          const rows = history ? (data ?? []).reverse() : (data ?? []);
          if (rows.length > 0 || Date.now() - started >= waitMs) return json({ messages: rows, typing: false, serverTime });
          await new Promise((r) => setTimeout(r, 1500));
        }
      }

      default:
        return json({ error: "Unknown action" }, 400);
    }
  } catch (err) {
    if (err instanceof HttpError) return json({ error: err.message }, err.status);
    return json({ error: String(err) }, 401);
  }
});
