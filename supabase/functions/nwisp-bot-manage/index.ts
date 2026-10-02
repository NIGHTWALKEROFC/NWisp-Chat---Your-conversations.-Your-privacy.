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

function publicBot(b: any, uid: string) {
  return {
    username: b.username,
    name: b.name,
    description: b.description,
    photo_data: b.photo_data ?? null,
    rules: b.rules,
    commands: b.rules?.commandsMenu ? (b.commands ?? []) : [],
    isOwner: b.owner_uid === uid,
  };
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
        return json({ bots: (data ?? []).map((b) => ({ ...publicBot(b, uid), webhook: !!b.webhook_url })) });
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
          bots: (started ?? []).filter((s) => byName.has(s.bot)).map((s) => ({
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
        if (!bot.rules?.public && bot.owner_uid !== uid) return json({ error: "This bot isn't open to everyone yet." }, 403);

        const { data: existing } = await db.from("bot_users").select("blocked, chat_id").eq("bot", username).eq("user_uid", uid).maybeSingle();
        if (existing?.blocked) return json({ error: "You blocked this bot. Unblock it first." }, 403);

        // Soft rate limit: 20 messages a minute from one person to one bot.
        const since = new Date(Date.now() - 60_000).toISOString();
        const { count: recent } = await db.from("bot_messages").select("id", { count: "exact", head: true })
          .eq("bot", username).eq("user_uid", uid).eq("direction", "in").gte("created_at", since);
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
        if (bot.rules?.webhook && bot.webhook_url) {
          const from: Record<string, unknown> = { id: chatId, is_bot: false, first_name: "User" };
          if (extra.username) { from.username = extra.username; from.first_name = extra.username; }
          const update = kind === "callback"
            ? { update_id: row.id, callback_query: { id: String(row.id), from, data: extra.data, message: { message_id: extra.messageId, chat: { id: chatId } } } }
            : { update_id: row.id, message: { message_id: row.id, from, chat: { id: chatId, type: "private" }, date: Math.floor(Date.now() / 1000), text } };
          fetch(bot.webhook_url, {
            method: "POST",
            headers: { "Content-Type": "application/json", "X-NWisp-Bot-Api-Secret-Token": bot.webhook_secret ?? "" },
            body: JSON.stringify(update),
            signal: AbortSignal.timeout(5000),
          }).then(async () => {
            // Delivered by webhook, so it counts as acknowledged.
            await db.from("bots").update({ update_cursor: row.id }).eq("username", username).lt("update_cursor", row.id);
          }).catch(() => {});
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
            .eq("bot", username).eq("user_uid", uid);
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
        await db.from("bot_messages").delete().eq("bot", username).eq("user_uid", uid);
        return json({ ok: true });
      }

      default:
        return json({ error: "Unknown action" }, 400);
    }
  } catch (err) {
    return json({ error: String(err) }, 401);
  }
});
