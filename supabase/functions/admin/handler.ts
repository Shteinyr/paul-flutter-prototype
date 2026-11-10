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
export async function handleAdmin(request: Request, database: SupabaseClient) {
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
    if (
      body.action !== "context" ||
      Object.keys(body).some((key) => key !== "action")
    ) {
      return reply(400, { code: "invalid_request" });
    }
    const { data: withinBudget, error: budgetError } = await database.rpc(
      "invite_request_limit",
      {
        p_bucket: "admin:" + auth.user.id,
        p_limit: 120,
        p_seconds: 60,
      },
    );
    if (budgetError) return reply(503, { code: "server_unavailable" });
    if (!withinBudget) return reply(429, { code: "rate_limited" });
    const { data, error } = await database.rpc("admin_context", {
      p_actor: auth.user.id,
    });
    if (error) {
      if (error.message === "admin_forbidden") {
        return reply(403, { code: "admin_forbidden" });
      }
      return reply(503, { code: "server_unavailable" });
    }
    return reply(200, data);
  } catch {
    // Never log profile data, auth credentials, or database internals.
    return reply(503, { code: "server_unavailable" });
  }
}
