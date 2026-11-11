import type { SupabaseClient } from "npm:@supabase/supabase-js@2.108.2";
import { decodeBase64, uuid } from "../push/shared.ts";

type Database = Pick<SupabaseClient, "auth" | "rpc">;
const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, apikey, content-type, x-client-info",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Cache-Control": "no-store",
};
const statuses: Record<string, number> = {
  invalid_request: 400,
  invalid_skill: 400,
  invalid_message: 400,
  request_too_large: 413,
  membership_required: 403,
  session_revoked: 401,
  community_locked: 403,
  community_forbidden: 403,
  operation_id_conflict: 409,
  rate_limited: 429,
};
const graphemes = new Intl.Segmenter("en", { granularity: "grapheme" });
const encoder = new TextEncoder();
const reply = (status: number, body: unknown) =>
  Response.json(body, { status, headers: cors });

async function readBody(request: Request): Promise<Record<string, unknown>> {
  const reader = request.body?.getReader();
  if (!reader) throw new Error("invalid_request");
  const chunks: Uint8Array[] = [];
  let size = 0;
  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    size += value.byteLength;
    if (size > 100000) {
      await reader.cancel();
      throw new Error("request_too_large");
    }
    chunks.push(value);
  }
  const bytes = new Uint8Array(size);
  let offset = 0;
  for (const chunk of chunks) {
    bytes.set(chunk, offset);
    offset += chunk.byteLength;
  }
  let body;
  try {
    body = JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(bytes));
  } catch {
    throw new Error("invalid_request");
  }
  if (!body || typeof body !== "object" || Array.isArray(body)) {
    throw new Error("invalid_request");
  }
  return body;
}

function text(value: unknown, limit: number, bytes: number): value is string {
  return typeof value === "string" && !!value.trim() && !value.includes("\0") &&
    encoder.encode(value).byteLength <= bytes &&
    [...graphemes.segment(value)].length <= limit;
}

export async function handleCommunity(
  request: Request,
  database: Database,
): Promise<Response> {
  if (request.method === "OPTIONS") {
    return new Response(null, { status: 204, headers: cors });
  }
  if (request.method !== "POST") {
    return reply(405, { code: "method_not_allowed" });
  }
  try {
    const bearer = request.headers.get("Authorization")?.match(
      /^Bearer ([^\s]+)$/i,
    )?.[1];
    if (!bearer || bearer.length > 8192) {
      return reply(401, { code: "sign_in_required" });
    }
    const { data: auth, error: authError } = await database.auth.getUser(
      bearer,
    );
    if (authError?.status === 429) return reply(429, { code: "rate_limited" });
    if (authError && (!authError.status || authError.status >= 500)) {
      return reply(503, { code: "server_unavailable" });
    }
    if (authError || !auth.user || auth.user.is_anonymous) {
      return reply(401, { code: "sign_in_required" });
    }
    let session: unknown;
    try {
      session =
        JSON.parse(new TextDecoder().decode(decodeBase64(bearer.split(".")[1])))
          .session_id;
    } catch {
      return reply(401, { code: "sign_in_required" });
    }
    if (!uuid(session)) return reply(401, { code: "sign_in_required" });
    const body = await readBody(request);
    const actions: Record<string, string[]> = {
      feed: ["cursor", "limit"],
      get: ["request_id"],
      create: ["client_operation_id", "skill", "message"],
      close: ["client_operation_id", "request_id"],
    };
    const action = String(body.action);
    if (
      !Object.hasOwn(actions, action) ||
      Object.keys(body).some((key) =>
        key !== "action" && !actions[action].includes(key)
      )
    ) {
      return reply(400, { code: "invalid_request" });
    }
    const args: Record<string, unknown> = {
      p_user: auth.user.id,
      p_session: session,
    };
    if (action === "create" || action === "close") {
      if (!uuid(body.client_operation_id)) {
        return reply(400, { code: "invalid_request" });
      }
      args.p_operation = body.client_operation_id;
    }
    if (action === "get" || action === "close") {
      if (!uuid(body.request_id)) {
        return reply(400, { code: "invalid_request" });
      }
      args.p_request = body.request_id;
    }
    if (action === "create") {
      const skill = typeof body.skill === "string"
        ? body.skill.trim().replace(/\s+/gu, " ")
        : body.skill;
      const message = typeof body.message === "string"
        ? body.message.trim()
        : body.message;
      if (!text(skill, 64, 32768)) return reply(400, { code: "invalid_skill" });
      if (!text(message, 2000, 65536)) {
        return reply(400, { code: "invalid_message" });
      }
      args.p_skill = skill;
      args.p_message = message;
    }
    if (action === "feed") {
      const limit = body.limit ?? 20;
      const cursor = body.cursor;
      if (!Number.isInteger(limit) || Number(limit) < 1 || Number(limit) > 50) {
        return reply(400, { code: "invalid_request" });
      }
      if (cursor != null) {
        if (
          typeof cursor !== "object" || Array.isArray(cursor) ||
          Object.keys(cursor).sort().join(",") !== "created_at,id"
        ) return reply(400, { code: "invalid_request" });
        const item = cursor as Record<string, unknown>;
        if (
          !uuid(item.id) || typeof item.created_at !== "string" ||
          !Number.isFinite(Date.parse(item.created_at))
        ) return reply(400, { code: "invalid_request" });
      }
      args.p_cursor = cursor ?? null;
      args.p_limit = limit;
    }
    const budget = await database.rpc("invite_request_limit", {
      p_bucket: "community:" + auth.user.id,
      p_limit: 120,
      p_seconds: 60,
    });
    if (budget.error) return reply(503, { code: "server_unavailable" });
    if (!budget.data) return reply(429, { code: "rate_limited" });
    const result = await database.rpc("community_" + action, args);
    if (result.error) {
      const code = Object.hasOwn(statuses, result.error.message)
        ? result.error.message
        : "server_unavailable";
      return reply(statuses[code] ?? 503, { code });
    }
    return reply(200, result.data);
  } catch (error) {
    const code =
      error instanceof Error && Object.hasOwn(statuses, error.message)
        ? error.message
        : "server_unavailable";
    return reply(statuses[code] ?? 503, { code });
  }
}
