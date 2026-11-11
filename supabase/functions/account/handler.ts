import type { SupabaseClient } from "npm:@supabase/supabase-js@2.108.2";
import { decodeBase64, readBody, uuid } from "../push/shared.ts";

type Database = Pick<SupabaseClient, "auth" | "rpc">;
const statuses: Record<string, number> = {
  invalid_request: 400,
  request_too_large: 413,
  membership_required: 403,
  session_revoked: 401,
  profile_unavailable: 404,
  rate_limited: 429,
};
const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, apikey, content-type, x-client-info",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Cache-Control": "no-store",
};
function reply(status: number, body: unknown) {
  return Response.json(body, { status, headers: cors });
}

export async function handleAccount(request: Request, database: Database) {
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
    const { data, error } = await database.auth.getUser(bearer);
    if (error?.status === 429) return reply(429, { code: "rate_limited" });
    if (error && (!error.status || error.status >= 500)) {
      return reply(503, { code: "server_unavailable" });
    }
    if (error || !data.user || data.user.is_anonymous) {
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
      capabilities: [],
      profile: ["profile_id"],
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
      p_user: data.user.id,
      p_session: session,
    };
    if (action === "profile") {
      if (!uuid(body.profile_id)) {
        return reply(400, { code: "invalid_request" });
      }
      args.p_profile = body.profile_id;
    }
    const { data: allowed, error: limitError } = await database.rpc(
      "invite_request_limit",
      {
        p_bucket: "account:" + data.user.id,
        p_limit: 120,
        p_seconds: 60,
      },
    );
    if (limitError) return reply(503, { code: "server_unavailable" });
    if (!allowed) return reply(429, { code: "rate_limited" });
    const result = await database.rpc("member_" + action, args);
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
