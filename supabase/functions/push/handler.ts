import {
  decodeBase64,
  errors,
  type PushConfig,
  type PushDatabase,
  readBody,
  uuid,
  validEndpoint,
  validKeys,
} from "./shared.ts";

export async function handlePush(
  request: Request,
  database: PushDatabase,
  config: PushConfig,
): Promise<Response> {
  const origin = request.headers.get("Origin");
  const headers: Record<string, string> = {
    "Content-Type": "application/json",
    "Cache-Control": "no-store",
    "Access-Control-Allow-Headers":
      "authorization, apikey, content-type, x-client-info",
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Vary": "Origin",
  };
  const reply = (status: number, body: unknown) =>
    new Response(JSON.stringify(body), { status, headers });
  if (origin && !config.allowedOrigins.includes(origin)) {
    return reply(403, { code: "push_forbidden" });
  }
  if (origin) headers["Access-Control-Allow-Origin"] = origin;
  if (request.method === "OPTIONS") {
    return new Response(null, { status: 204, headers });
  }
  if (request.method !== "POST") {
    return reply(405, { code: "method_not_allowed" });
  }
  try {
    const body = await readBody(request);
    const fields: Record<string, string[]> = {
      config: [],
      subscribe: ["binding_id", "subscription"],
      status: ["binding_id"],
      unsubscribe: ["binding_id"],
      resolve: ["binding_id", "delivery_id"],
    };
    const action = String(body.action);
    if (
      !Object.hasOwn(fields, action) ||
      Object.keys(body).some((key) =>
        key !== "action" && !fields[action].includes(key)
      )
    ) {
      return reply(400, { code: "invalid_request" });
    }
    const enabled = config.enabled && !!config.publicKey &&
      !!config.privateKey && !!config.subject;
    if (action === "config") {
      return reply(200, {
        version: 1,
        enabled,
        vapid_public_key: enabled ? config.publicKey : null,
      });
    }
    if (!enabled) return reply(503, { code: "server_unavailable" });
    const bearer = request.headers.get("Authorization")?.match(
      /^Bearer ([^\s]+)$/i,
    )?.[1];
    if (!bearer || bearer.length > 8192) {
      return reply(401, { code: "sign_in_required" });
    }
    const { data: auth, error } = await database.auth.getUser(bearer);
    if (error?.status === 429) return reply(429, { code: "rate_limited" });
    if (error && (!error.status || error.status >= 500)) {
      return reply(503, { code: "server_unavailable" });
    }
    if (error || !auth.user || auth.user.is_anonymous) {
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
    if (!uuid(body.binding_id)) return reply(400, { code: "invalid_request" });
    const args: Record<string, unknown> = {
      p_user: auth.user.id,
      p_session: session,
      p_binding: body.binding_id,
    };
    if (action === "subscribe") {
      const sub = body.subscription as Record<string, unknown> | null;
      if (
        !sub || typeof sub !== "object" || Array.isArray(sub) ||
        Object.keys(sub).some((key) =>
          !["endpoint", "expirationTime", "keys"].includes(key)
        ) ||
        !validEndpoint(sub.endpoint) || !await validKeys(sub.keys)
      ) return reply(400, { code: "invalid_request" });
      const expiry = sub.expirationTime;
      if (
        expiry !== undefined && expiry !== null &&
        (typeof expiry !== "number" || !Number.isSafeInteger(expiry) ||
          expiry <= Date.now() || expiry > 8640000000000000)
      ) {
        return reply(400, { code: "invalid_request" });
      }
      const keys = sub.keys as { p256dh: string; auth: string };
      Object.assign(args, {
        p_endpoint: sub.endpoint,
        p_p256dh: keys.p256dh,
        p_auth: keys.auth,
        p_expires: typeof expiry === "number"
          ? new Date(expiry).toISOString()
          : null,
      });
    }
    if (action === "resolve") {
      if (!uuid(body.delivery_id)) {
        return reply(400, { code: "invalid_request" });
      }
      args.p_delivery = body.delivery_id;
    }
    const { data, error: failed } = await database.rpc("push_" + action, args);
    if (failed) {
      const code = Object.hasOwn(errors, failed.message)
        ? failed.message
        : "server_unavailable";
      return reply(errors[code] ?? 503, { code });
    }
    return reply(200, data);
  } catch (error) {
    const code = error instanceof Error &&
        ["request_too_large", "invalid_request"].includes(error.message)
      ? error.message
      : "server_unavailable";
    return reply(errors[code] ?? 503, { code });
  }
}
