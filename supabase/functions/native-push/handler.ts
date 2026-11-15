import { decodeBase64, type PushDatabase, readBody } from "../push/shared.ts";

const uuid =
  /^[a-fA-F0-9]{8}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{12}$/;
const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization,apikey,content-type,x-client-info",
  "Access-Control-Allow-Methods": "POST,OPTIONS",
};
export async function handleNativePush(
  request: Request,
  database: PushDatabase,
): Promise<Response> {
  const reply = (status: number, body: unknown) =>
    Response.json(body, {
      status,
      headers: { ...cors, "Cache-Control": "no-store" },
    });
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
    const verified = await database.auth.getUser(bearer);
    if (
      verified.error || !verified.data.user || verified.data.user.is_anonymous
    ) return reply(401, { code: "sign_in_required" });
    let session: unknown;
    try {
      session =
        JSON.parse(new TextDecoder().decode(decodeBase64(bearer.split(".")[1])))
          .session_id;
    } catch {
      return reply(401, { code: "sign_in_required" });
    }
    if (typeof session !== "string" || !uuid.test(session)) {
      return reply(401, { code: "sign_in_required" });
    }
    let body: Record<string, unknown>;
    try {
      body = await readBody(request);
    } catch (error) {
      const oversized = error instanceof Error &&
        error.message === "request_too_large";
      return reply(oversized ? 413 : 400, {
        code: oversized ? "request_too_large" : "invalid_request",
      });
    }
    const action = String(body.action);
    const allowed: Record<string, string[]> = {
      subscribe: ["binding_id", "token", "platform"],
      unsubscribe: ["binding_id"],
      resolve: ["binding_id", "delivery_id"],
    };
    if (
      !Object.hasOwn(allowed, action) || Object.keys(body).some((key) =>
        key !== "action" && !allowed[action].includes(key)
      ) ||
      typeof body.binding_id !== "string" || !uuid.test(body.binding_id)
    ) {
      return reply(400, { code: "invalid_request" });
    }
    const args: Record<string, unknown> = {
      p_user: verified.data.user.id,
      p_session: session,
      p_binding: body.binding_id,
    };
    if (action === "subscribe") {
      if (
        typeof body.token !== "string" ||
        new TextEncoder().encode(body.token).length < 20 ||
        new TextEncoder().encode(body.token).length > 4096 ||
        !/^[A-Za-z0-9_:.\-]+$/.test(body.token) ||
        (body.platform !== "ios" && body.platform !== "android")
      ) {
        return reply(400, { code: "invalid_request" });
      }
      args.p_token = body.token;
      args.p_token_hash = Array.from(
        new Uint8Array(
          await crypto.subtle.digest(
            "SHA-256",
            new TextEncoder().encode(body.token),
          ),
        ),
      )
        .map((byte) =>
          byte.toString(16).padStart(2, "0")
        ).join("");
      args.p_platform = body.platform;
    }
    if (action === "resolve") {
      if (
        typeof body.delivery_id !== "string" || !uuid.test(body.delivery_id)
      ) return reply(400, { code: "invalid_request" });
      args.p_delivery = body.delivery_id;
    }
    const budget = await database.rpc("invite_request_limit", {
      p_bucket: "native-push:" + verified.data.user.id,
      p_limit: 120,
      p_seconds: 60,
    });
    if (budget.error) return reply(503, { code: "server_unavailable" });
    if (!budget.data) return reply(429, { code: "rate_limited" });
    const result = await database.rpc("native_push_" + action, args);
    if (result.error) {
      const known: Record<string, number> = {
        session_admission_required: 403,
        session_revoked: 401,
        push_forbidden: 403,
        invalid_request: 400,
        rate_limited: 429,
      };
      const code = Object.hasOwn(known, result.error.message)
        ? result.error.message
        : "server_unavailable";
      return reply(known[code] ?? 503, { code });
    }
    return reply(200, result.data ?? { ok: true });
  } catch {
    return reply(503, { code: "server_unavailable" });
  }
}
