import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

// Feature: NWisp Bots — the Bot API. This is what a bot's own program (running
// wherever its owner hosts it) talks to, in the same style as Telegram:
//
//   https://<your-project>.supabase.co/functions/v1/nwisp-bot-api/bot<TOKEN>/<method>
//
// Methods: getMe, getUpdates, sendMessage, sendPhoto, editMessageText,
// deleteMessage, sendChatAction, answerCallbackQuery, setWebhook,
// deleteWebhook, getWebhookInfo, setMyCommands, getMyCommands.
//
// Send parameters either as a JSON body or in the query string. Every answer
// is JSON: { ok: true, result: … } or { ok: false, error_code, description }.
//
// The bot's rules (switched on in the NWisp app) are enforced here: a method
// the owner hasn't allowed answers 403 and says which switch to turn on.
//
// Turn OFF "Enforce JWT verification" for this function: bots authenticate
// with their own token, not a Supabase login.

const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
  auth: { persistSession: false },
});
const CORS = { "Access-Control-Allow-Origin": "*", "Access-Control-Allow-Headers": "content-type" };
const reply = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...CORS, "Content-Type": "application/json" } });
const ok = (result: unknown) => reply({ ok: true, result });
const fail = (code: number, description: string, extra: Record<string, unknown> = {}) =>
  reply({ ok: false, error_code: code, description, ...extra }, code);

async function sha256Hex(text: string): Promise<string> {
  const buf = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text));
  return [...new Uint8Array(buf)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

/** Webhook addresses must be public https addresses (no localhost / private networks). */
function safeWebhook(u: string): boolean {
  try {
    const url = new URL(u);
    if (url.protocol !== "https:") return false;
    if (url.port && !["443", "8443"].includes(url.port)) return false;
    const h = url.hostname.toLowerCase();
    if (h === "localhost" || h.endsWith(".local") || h.endsWith(".internal") || h.endsWith(".localhost")) return false;
    if (h.includes(":") || h.startsWith("[")) return false; // IPv6 literals
    const m = h.match(/^(\d+)\.(\d+)\.(\d+)\.(\d+)$/);
    if (m) {
      const [a, b] = [Number(m[1]), Number(m[2])];
      if (a === 10 || a === 127 || a === 0 || (a === 169 && b === 254) || (a === 172 && b >= 16 && b <= 31) || (a === 192 && b === 168)) return false;
    }
    return true;
  } catch (_) {
    return false;
  }
}

function safeHttps(u: unknown): u is string {
  try {
    return typeof u === "string" && new URL(u).protocol === "https:";
  } catch (_) {
    return false;
  }
}

function sanitizeKeyboard(markup: any): any[][] | null {
  const rows = markup?.inline_keyboard;
  if (!Array.isArray(rows)) return null;
  const out: any[][] = [];
  for (const row of rows.slice(0, 8)) {
    if (!Array.isArray(row)) continue;
    const r: any[] = [];
    for (const b of row.slice(0, 4)) {
      const text = String(b?.text ?? "").slice(0, 40);
      if (!text) continue;
      if (typeof b.callback_data === "string") r.push({ text, callback_data: b.callback_data.slice(0, 64) });
      else if (safeHttps(b.url)) r.push({ text, url: b.url });
    }
    if (r.length) out.push(r);
  }
  return out;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  try {
    const url = new URL(req.url);
    // Path looks like /nwisp-bot-api/bot<TOKEN>/<method>
    const parts = url.pathname.split("/").filter(Boolean);
    const botPart = parts.find((p) => p.startsWith("bot") && p.includes(":"));
    if (!botPart) return fail(404, "Not found. Use /bot<TOKEN>/<method>");
    const method = parts[parts.indexOf(botPart) + 1] ?? "";
    const token = botPart.slice(3);
    const [idStr, secret] = token.split(":");
    const botId = Number(idStr);
    if (!Number.isFinite(botId) || !secret) return fail(401, "Unauthorized");

    const { data: bot } = await db.from("bots").select("*").eq("bot_id", botId).maybeSingle();
    if (!bot || bot.token_hash !== (await sha256Hex(secret))) return fail(401, "Unauthorized");
    const rules = bot.rules ?? {};

    // Parameters: query string first, then JSON body on top.
    const params: Record<string, any> = Object.fromEntries(url.searchParams.entries());
    if (req.method === "POST") {
      try {
        const b = await req.json();
        if (b && typeof b === "object") Object.assign(params, b);
      } catch (_) { /* no body */ }
    }
    const need = (rule: string, label: string) =>
      rules[rule] ? null : fail(403, `${label} is turned off for this bot. Turn on "${rule}" in NWisp > Bots > ${bot.name} > Rules.`);

    // Find the person behind a chat_id — only people who started THIS bot.
    const chatUser = async (chat_id: unknown) => {
      const { data } = await db.from("bot_users").select("user_uid, blocked, chat_id").eq("bot", bot.username).eq("chat_id", Number(chat_id)).maybeSingle();
      return data;
    };

    // Per-bot send limit: 300 outgoing messages a minute.
    const checkSendLimit = async () => {
      const since = new Date(Date.now() - 60_000).toISOString();
      const { count } = await db.from("bot_messages").select("id", { count: "exact", head: true })
        .eq("bot", bot.username).eq("direction", "out").gte("created_at", since);
      return (count ?? 0) >= 300 ? fail(429, "Too many messages. Slow down.", { parameters: { retry_after: 10 } }) : null;
    };

    const messageOut = (r: any, chatId: number, text: string) => ({
      message_id: r.id, chat: { id: chatId, type: "private" }, date: Math.floor(new Date(r.created_at).getTime() / 1000), text,
      from: { id: bot.bot_id, is_bot: true, username: bot.username, first_name: bot.name },
    });

    switch (method) {
      case "getMe":
        return ok({ id: bot.bot_id, is_bot: true, first_name: bot.name, username: bot.username, description: bot.description });

      // ---------------------------------------------------------- getUpdates
      case "getUpdates": {
        if (bot.webhook_url) return fail(409, "A webhook is set. Call deleteWebhook before using getUpdates.");
        const offset = Number(params.offset ?? 0);
        const limit = Math.min(Math.max(Number(params.limit ?? 100), 1), 100);
        const waitMs = Math.min(Math.max(Number(params.timeout ?? 0), 0), 25) * 1000;
        // offset N means "I have handled everything before N".
        if (offset > 0 && offset - 1 > bot.update_cursor) {
          await db.from("bots").update({ update_cursor: offset - 1 }).eq("bot_id", bot.bot_id);
          bot.update_cursor = offset - 1;
        }
        const started = Date.now();
        while (true) {
          const { data } = await db.from("bot_messages").select("*").eq("bot", bot.username).eq("direction", "in")
            .gt("id", bot.update_cursor).order("id", { ascending: true }).limit(limit);
          if ((data ?? []).length > 0 || Date.now() - started >= waitMs) {
            const users = new Map<string, number>();
            const updates = [];
            for (const m of data ?? []) {
              if (!users.has(m.user_uid)) {
                const { data: bu } = await db.from("bot_users").select("chat_id").eq("bot", bot.username).eq("user_uid", m.user_uid).maybeSingle();
                users.set(m.user_uid, bu?.chat_id ?? 0);
              }
              const chatId = users.get(m.user_uid)!;
              const from: Record<string, unknown> = { id: chatId, is_bot: false, first_name: "User" };
              if (m.extra?.username) { from.username = m.extra.username; from.first_name = m.extra.username; }
              updates.push(
                m.kind === "callback"
                  ? { update_id: m.id, callback_query: { id: String(m.id), from, data: m.extra?.data, message: { message_id: m.extra?.messageId, chat: { id: chatId } } } }
                  : { update_id: m.id, message: { message_id: m.id, from, chat: { id: chatId, type: "private" }, date: Math.floor(new Date(m.created_at).getTime() / 1000), text: m.body } },
              );
            }
            return ok(updates);
          }
          await new Promise((r) => setTimeout(r, 1500));
        }
      }

      // --------------------------------------------------------- sendMessage
      case "sendMessage": {
        const cu = await chatUser(params.chat_id);
        if (!cu) return fail(400, "Chat not found. A person has to start the bot first.");
        if (cu.blocked) return fail(403, "The user blocked the bot.");
        const limited = await checkSendLimit();
        if (limited) return limited;
        let text = String(params.text ?? "");
        if (!text) return fail(400, "Message text is empty.");
        const max = rules.longMessages ? 4000 : 1000;
        if (text.length > max) {
          return fail(400, `Message is too long (limit ${max}). ${rules.longMessages ? "" : 'Turn on "longMessages" to allow 4000.'}`);
        }
        const extra: Record<string, unknown> = {};
        if (params.reply_markup) {
          const denied = need("buttons", "Inline buttons");
          if (denied) return denied;
          let markup = params.reply_markup;
          if (typeof markup === "string") { try { markup = JSON.parse(markup); } catch (_) { markup = null; } }
          const kb = sanitizeKeyboard(markup);
          if (kb) extra.buttons = kb;
        }
        if (params.parse_mode) extra.format = rules.formatting ? true : false; // ignored (plain text) unless allowed
        const { data: row, error } = await db.from("bot_messages")
          .insert({ bot: bot.username, user_uid: cu.user_uid, direction: "out", body: text, extra }).select().single();
        if (error) return fail(500, "Couldn't send.");
        return ok(messageOut(row, cu.chat_id, text));
      }

      // ----------------------------------------------------------- sendPhoto
      case "sendPhoto": {
        const denied = need("media", "Sending photos");
        if (denied) return denied;
        const cu = await chatUser(params.chat_id);
        if (!cu) return fail(400, "Chat not found. A person has to start the bot first.");
        if (cu.blocked) return fail(403, "The user blocked the bot.");
        if (!safeHttps(params.photo)) return fail(400, "photo must be a public https:// link to an image.");
        const limited = await checkSendLimit();
        if (limited) return limited;
        const caption = String(params.caption ?? "").slice(0, 1000);
        const extra: Record<string, unknown> = { photo: params.photo };
        if (params.reply_markup && rules.buttons) {
          let markup = params.reply_markup;
          if (typeof markup === "string") { try { markup = JSON.parse(markup); } catch (_) { markup = null; } }
          const kb = sanitizeKeyboard(markup);
          if (kb) extra.buttons = kb;
        }
        const { data: row } = await db.from("bot_messages")
          .insert({ bot: bot.username, user_uid: cu.user_uid, direction: "out", kind: "photo", body: caption, extra }).select().single();
        return ok(messageOut(row, cu.chat_id, caption));
      }

      // ----------------------------------------------- editMessageText / delete
      case "editMessageText":
      case "deleteMessage": {
        const denied = need("editDelete", "Editing and deleting messages");
        if (denied) return denied;
        const cu = await chatUser(params.chat_id);
        if (!cu) return fail(400, "Chat not found.");
        const { data: msg } = await db.from("bot_messages").select("id").eq("id", Number(params.message_id))
          .eq("bot", bot.username).eq("user_uid", cu.user_uid).eq("direction", "out").maybeSingle();
        if (!msg) return fail(400, "Message not found (a bot can only change its own messages).");
        if (method === "deleteMessage") {
          await db.from("bot_messages").update({ deleted: true, body: "", extra: {}, updated_at: new Date().toISOString() }).eq("id", msg.id);
          return ok(true);
        }
        const text = String(params.text ?? "");
        if (!text || text.length > (rules.longMessages ? 4000 : 1000)) return fail(400, "Bad text length.");
        const patch: Record<string, unknown> = { body: text, edited: true, updated_at: new Date().toISOString() };
        if (params.reply_markup && rules.buttons) {
          let markup = params.reply_markup;
          if (typeof markup === "string") { try { markup = JSON.parse(markup); } catch (_) { markup = null; } }
          const kb = sanitizeKeyboard(markup);
          patch.extra = kb ? { buttons: kb } : {};
        }
        await db.from("bot_messages").update(patch).eq("id", msg.id);
        return ok(true);
      }

      // ------------------------------------------------------- sendChatAction
      case "sendChatAction": {
        const denied = need("typing", "The typing indicator");
        if (denied) return denied;
        const cu = await chatUser(params.chat_id);
        if (!cu) return fail(400, "Chat not found.");
        await db.from("bot_users").update({ typing_until: new Date(Date.now() + 5000).toISOString() })
          .eq("bot", bot.username).eq("user_uid", cu.user_uid);
        return ok(true);
      }

      case "answerCallbackQuery": {
        const denied = need("buttons", "Inline buttons");
        if (denied) return denied;
        return ok(true); // button taps need no extra answer in NWisp; returned for Telegram-style bots
      }

      // ------------------------------------------------------------- webhooks
      case "setWebhook": {
        const denied = need("webhook", "Webhooks");
        if (denied) return denied;
        if (!safeWebhook(String(params.url ?? ""))) {
          return fail(400, "url must be a public https:// address (port 443 or 8443).");
        }
        const secretToken = String(params.secret_token ?? "").slice(0, 256);
        await db.from("bots").update({ webhook_url: params.url, webhook_secret: secretToken }).eq("bot_id", bot.bot_id);
        return ok(true);
      }
      case "deleteWebhook":
        await db.from("bots").update({ webhook_url: null, webhook_secret: null }).eq("bot_id", bot.bot_id);
        return ok(true);
      case "getWebhookInfo":
        return ok({ url: bot.webhook_url ?? "", has_custom_certificate: false });

      // -------------------------------------------------------------- commands
      case "setMyCommands": {
        let list = params.commands;
        if (typeof list === "string") { try { list = JSON.parse(list); } catch (_) { list = null; } }
        if (!Array.isArray(list) || list.length > 30) return fail(400, "commands must be a list of up to 30 items.");
        const cleaned = list
          .map((c: any) => ({ command: String(c?.command ?? "").toLowerCase().replace(/^\//, "").slice(0, 32), description: String(c?.description ?? "").slice(0, 100) }))
          .filter((c: any) => /^[a-z0-9_]{1,32}$/.test(c.command));
        await db.from("bots").update({ commands: cleaned }).eq("bot_id", bot.bot_id);
        return ok(true);
      }
      case "getMyCommands":
        return ok(bot.commands ?? []);

      default:
        return fail(404, `Unknown method: ${method}`);
    }
  } catch (err) {
    return fail(500, `Server error: ${String(err)}`);
  }
});
