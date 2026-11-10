import type { SupabaseClient } from "npm:@supabase/supabase-js@2.108.2";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, apikey, content-type, x-client-info",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
function reply(status: number, data: unknown) {
  return new Response(JSON.stringify(data), {
    status,
    headers: {
      ...cors,
      "Content-Type": "application/json",
      "Cache-Control": "no-store",
    },
  });
}
const uuid = (value: unknown): value is string =>
  typeof value === "string" &&
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(value);
const cursor = (value: unknown) =>
  Number.isSafeInteger(value) && Number(value) >= 0;
const graphemes = new Intl.Segmenter("en", { granularity: "grapheme" });
const statuses: Record<string, number> = {
  membership_required: 403,
  conversation_forbidden: 403,
  self_conversation: 400,
  invalid_request: 400,
  invalid_message: 400,
  message_id_conflict: 409,
  rate_limited: 429,
};

export async function handleChat(request: Request, database: SupabaseClient) {
  if (request.method === "OPTIONS") {
    return new Response("ok", { headers: cors });
  }
  if (request.method !== "POST") {
    return reply(405, { code: "method_not_allowed" });
  }
  try {
    const bearer = request.headers.get("Authorization")?.match(/^Bearer (.+)$/i)
      ?.[1];
    if (!bearer) return reply(401, { code: "sign_in_required" });
    const { data: auth, error: authError } = await database.auth.getUser(
      bearer,
    );
    if (authError || !auth.user || auth.user.is_anonymous) {
      return reply(401, { code: "sign_in_required" });
    }
    // Bound bytes before accumulation, including requests without Content-Length.
    // This follows the invitation endpoint's bounded reader.
    const reader = request.body?.getReader();
    if (!reader) return reply(400, { code: "invalid_request" });
    const chunks: Uint8Array[] = [];
    let size = 0;
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      size += value.byteLength;
      if (size > 70000) {
        await reader.cancel();
        return reply(413, { code: "request_too_large" });
      }
      chunks.push(value);
    }
    const bytes = new Uint8Array(size);
    let offset = 0;
    for (const chunk of chunks) {
      bytes.set(chunk, offset);
      offset += chunk.length;
    }
    const raw = new TextDecoder().decode(bytes);
    let body: Record<string, unknown>;
    try {
      const parsed = JSON.parse(raw);
      if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
        throw new Error();
      }
      body = parsed;
    } catch {
      return reply(400, { code: "invalid_request" });
    }
    const allowed: Record<string, string[]> = {
      list: [],
      open: ["peer_id"],
      history: ["conversation_id", "before_seq", "after_seq", "limit"],
      send: ["conversation_id", "client_message_id", "text"],
      read: ["conversation_id", "through_seq"],
    };
    const action = String(body.action);
    if (
      !Object.hasOwn(allowed, action) ||
      Object.keys(body).some((key) =>
        key !== "action" && !allowed[action].includes(key)
      )
    ) {
      return reply(400, { code: "invalid_request" });
    }
    const { data: withinBudget, error: budgetError } = await database.rpc(
      "invite_request_limit",
      {
        p_bucket: "chat:" + auth.user.id,
        p_limit: 240,
        p_seconds: 60,
      },
    );
    if (budgetError) return reply(503, { code: "server_unavailable" });
    if (!withinBudget) return reply(429, { code: "rate_limited" });
    const args: Record<string, unknown> = { p_user: auth.user.id };
    if (action === "open") {
      if (!uuid(body.peer_id)) return reply(400, { code: "invalid_request" });
      args.p_peer = body.peer_id;
    } else if (action !== "list") {
      if (!uuid(body.conversation_id)) {
        return reply(400, { code: "invalid_request" });
      }
      args.p_conversation = body.conversation_id;
    }
    if (action === "history") {
      if (
        (body.before_seq != null &&
          (!cursor(body.before_seq) || body.before_seq === 0)) ||
        (body.after_seq != null && !cursor(body.after_seq)) ||
        (body.before_seq != null && body.after_seq != null) ||
        (body.limit != null &&
          (!Number.isInteger(body.limit) || Number(body.limit) < 1 ||
            Number(body.limit) > 100))
      ) {
        return reply(400, { code: "invalid_request" });
      }
      args.p_before = body.before_seq ?? null;
      args.p_after = body.after_seq ?? null;
      args.p_limit = body.limit ?? 50;
    }
    if (action === "send") {
      if (
        !uuid(body.client_message_id) || typeof body.text !== "string" ||
        !body.text.trim() || body.text.includes("\0") ||
        Array.from(graphemes.segment(body.text)).length > 2000 ||
        new TextEncoder().encode(body.text).length > 65536
      ) {
        return reply(400, { code: "invalid_message" });
      }
      args.p_client_message = body.client_message_id;
      args.p_text = body.text;
    }
    if (action === "read") {
      if (!cursor(body.through_seq)) {
        return reply(400, { code: "invalid_request" });
      }
      args.p_through = body.through_seq;
    }
    const { data, error } = await database.rpc("chat_" + action, args);
    if (error) {
      const code = Object.hasOwn(statuses, error.message)
        ? error.message
        : "server_unavailable";
      return reply(statuses[code] ?? 503, { code });
    }
    return reply(200, data);
  } catch {
    // Never log messages, auth credentials, or database internals.
    return reply(503, { code: "server_unavailable" });
  }
}
