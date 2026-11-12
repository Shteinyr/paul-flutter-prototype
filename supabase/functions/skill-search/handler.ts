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

export async function handleSkillSearch(
  request: Request,
  service: SupabaseClient,
  userClient: (token: string) => SupabaseClient,
) {
  if (request.method === "OPTIONS") {
    return new Response("ok", { headers: cors });
  }
  if (request.method !== "POST") {
    return reply(405, { code: "method_not_allowed" });
  }
  try {
    const token = request.headers.get("Authorization")?.match(/^Bearer (.+)$/i)
      ?.[1];
    if (!token) return reply(401, { code: "sign_in_required" });
    const { data: auth, error: authError } = await service.auth.getUser(token);
    if (authError || !auth.user || auth.user.is_anonymous) {
      return reply(401, { code: "sign_in_required" });
    }
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
    let body: Record<string, unknown>;
    try {
      const parsed = JSON.parse(new TextDecoder().decode(bytes));
      if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
        throw new Error();
      }
      body = parsed;
    } catch {
      return reply(400, { code: "invalid_request" });
    }
    const allowed = ["action", "query", "kind", "limit", "cursor"];
    const kind = body.kind === undefined ? "all" : body.kind;
    const limit = body.limit === undefined
      ? (body.action === "suggest" ? 10 : 20)
      : body.limit;
    if (
      (!["suggest", "search", "search_names"].includes(String(body.action))) ||
      Object.keys(body).some((key) => !allowed.includes(key)) ||
      typeof body.query !== "string" || !body.query.trim() ||
      body.query.includes("\0") ||
      (body.action === "search_names" && [...body.query.trim()].length < 2) ||
      (body.action === "search_names" && kind !== "all") ||
      new TextEncoder().encode(body.query).byteLength > 32768 ||
      typeof kind !== "string" ||
      !["all", "offering", "hiring"].includes(kind) ||
      !Number.isInteger(limit) || Number(limit) < 1 || Number(limit) > 50 ||
      (body.action === "suggest" && Object.hasOwn(body, "cursor")) ||
      (body.cursor != null &&
        (typeof body.cursor !== "object" || Array.isArray(body.cursor)))
    ) {
      return reply(400, { code: "invalid_request" });
    }
    // The privileged client verifies Auth and budgets only. Profile reads use
    // this request's captured JWT, including concurrent requests from other users.
    const { data: budget, error: budgetError } = await service.rpc(
      "invite_request_limit",
      { p_bucket: "skill-search:" + auth.user.id, p_limit: 120, p_seconds: 60 },
    );
    if (budgetError) return reply(503, { code: "server_unavailable" });
    if (!budget) return reply(429, { code: "rate_limited" });
    const args: Record<string, unknown> = {
      p_query: body.query,
      p_kind: kind,
      p_limit: limit,
    };
    if (body.action !== "suggest") args.p_cursor = body.cursor ?? null;
    if (body.action === "search_names") delete args.p_kind;
    const { data, error } = await userClient(token).rpc(
      body.action === "search_names"
        ? "profile_name_search"
        : body.action === "suggest"
        ? "skill_suggest"
        : "skill_search",
      args,
    );
    if (error) {
      if (error.message === "session_revoked") {
        return reply(401, { code: "session_revoked" });
      }
      if (error.message === "membership_required") {
        return reply(403, { code: "membership_required" });
      }
      if (error.message === "invalid_request") {
        return reply(400, { code: "invalid_request" });
      }
      if (error.code === "PGRST301" || error.code === "PGRST303") {
        return reply(401, { code: "sign_in_required" });
      }
      return reply(503, { code: "server_unavailable" });
    }
    if (!data || typeof data !== "object" || Array.isArray(data)) {
      return reply(503, { code: "server_unavailable" });
    }
    return reply(200, data);
  } catch {
    return reply(503, { code: "server_unavailable" });
  }
}
