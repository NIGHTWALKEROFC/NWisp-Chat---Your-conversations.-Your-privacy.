// Small shared helper for the "escalating throttle" kept in the
// `abuse_throttle` table (created by supabase/migrations/0005_device_abuse_throttle.sql).
//
// One row per (subject, action). A `subject` is a tagged value such as
// "ip:1.2.3.4" or "device:<uuid>"; `action` keeps different features'
// allowances separate (spamming password resets doesn't use up anyone's
// signup allowance). Within a rolling window each subject gets `limit`
// tries; going over blocks it for 1 hour the first time and 1 day every time
// after that.
//
// Honest limit (same as the migration notes): an IP changes when someone
// switches networks and a device id changes if the app is reinstalled, so
// this slows abuse down — it can't stop a determined person. Tracking BOTH
// means "just try again on other WiFi" alone no longer resets a block.

import type { SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2";

const FIRST_BLOCK_SECONDS = 60 * 60;
const REPEAT_BLOCK_SECONDS = 24 * 60 * 60;

export function clientIp(req: Request): string | null {
  const forwarded = req.headers.get("x-forwarded-for");
  if (forwarded) return forwarded.split(",")[0].trim() || null;
  return req.headers.get("cf-connecting-ip") ?? req.headers.get("x-real-ip");
}

export function subjectsFor(req: Request, deviceId: unknown): string[] {
  const subjects: string[] = [];
  const ip = clientIp(req);
  if (ip) subjects.push(`ip:${ip}`);
  if (typeof deviceId === "string" && deviceId.length >= 8 && deviceId.length <= 100) {
    subjects.push(`device:${deviceId}`);
  }
  return subjects;
}

/** Counts one attempt for each subject. Returns how long the caller must wait
 *  (seconds) if ANY subject is blocked, otherwise null. */
export async function bumpThrottle(
  supabase: SupabaseClient,
  subjects: string[],
  action: string,
  opts: { limit: number; windowSeconds: number },
): Promise<number | null> {
  let worstWait: number | null = null;
  const now = Date.now();

  for (const subject of subjects) {
    const { data: row } = await supabase
      .from("abuse_throttle")
      .select("count, window_started_at, escalation_level, blocked_until")
      .eq("subject", subject)
      .eq("action", action)
      .maybeSingle();

    if (row?.blocked_until) {
      const until = new Date(row.blocked_until).getTime();
      if (until > now) {
        worstWait = Math.max(worstWait ?? 0, Math.ceil((until - now) / 1000));
        continue;
      }
    }

    const windowStart = row ? new Date(row.window_started_at).getTime() : now;
    const windowExpired = !row || now - windowStart > opts.windowSeconds * 1000;
    const count = windowExpired ? 1 : (row!.count ?? 0) + 1;
    const level = row?.escalation_level ?? 0;

    if (count > opts.limit) {
      const newLevel = level + 1;
      const blockSeconds = newLevel <= 1 ? FIRST_BLOCK_SECONDS : REPEAT_BLOCK_SECONDS;
      await supabase.from("abuse_throttle").upsert({
        subject,
        action,
        count: 0,
        window_started_at: new Date(now).toISOString(),
        escalation_level: newLevel,
        blocked_until: new Date(now + blockSeconds * 1000).toISOString(),
      });
      worstWait = Math.max(worstWait ?? 0, blockSeconds);
    } else {
      await supabase.from("abuse_throttle").upsert({
        subject,
        action,
        count,
        window_started_at: new Date(windowExpired ? now : windowStart).toISOString(),
        escalation_level: level,
        blocked_until: null,
      });
    }
  }
  return worstWait;
}

export function describeWait(seconds: number): string {
  if (seconds < 90) return `${seconds} seconds`;
  if (seconds < 5400) return `${Math.ceil(seconds / 60)} minutes`;
  if (seconds < 172800) return `${Math.ceil(seconds / 3600)} hours`;
  return `${Math.ceil(seconds / 86400)} days`;
}
