type Database = {
  rpc: (name: string, args: Record<string, unknown>) => PromiseLike<{
    data: unknown;
    error: { message: string } | null;
  }>;
};
type Signer = (paths: string[]) => Promise<Map<string, string>>;
const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, apikey, content-type, x-client-info",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Cache-Control": "no-store",
};
const reply = (status: number, data: unknown) =>
  Response.json(data, { status, headers: cors });
const uuid = (value: unknown): value is string =>
  typeof value === "string" &&
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(value);
const object = (value: unknown): value is Record<string, unknown> =>
  !!value && typeof value === "object" && !Array.isArray(value);

async function bodyOf(request: Request): Promise<Record<string, unknown>> {
  const reader = request.body?.getReader();
  if (!reader) throw Error("invalid_request");
  const chunks: Uint8Array[] = [];
  let size = 0;
  for (;;) {
    const { value, done } = await reader.read();
    if (done) break;
    size += value.byteLength;
    if (size > 4096) {
      await reader.cancel();
      throw Error("request_too_large");
    }
    chunks.push(value);
  }
  const bytes = new Uint8Array(size);
  let offset = 0;
  for (const chunk of chunks) {
    bytes.set(chunk, offset);
    offset += chunk.length;
  }
  const data = JSON.parse(
    new TextDecoder("utf-8", { fatal: true }).decode(bytes),
  );
  if (!object(data)) throw Error("invalid_request");
  return data;
}

// Rebuild the response explicitly: a future SQL addition must not expose a private field.
function profile(value: unknown, urls: Map<string, string>): unknown {
  if (value == null) return null;
  if (
    !object(value) || !uuid(value.id) || typeof value.name !== "string" ||
    typeof value.occupation !== "string" || typeof value.summary !== "string" ||
    !Array.isArray(value.skills) ||
    !value.skills.every((s) => typeof s === "string") ||
    !Array.isArray(value.searching_skills) ||
    !value.searching_skills.every((s) => typeof s === "string")
  ) throw Error("server_unavailable");
  return {
    id: value.id,
    name: value.name,
    occupation: value.occupation,
    summary: value.summary,
    skills: value.skills,
    searching_skills: value.searching_skills,
    contact_count: Number.isSafeInteger(value.contact_count) &&
        Number(value.contact_count) >= 0
      ? value.contact_count
      : 0,
    avatar_url: typeof value.avatar_path === "string"
      ? urls.get(value.avatar_path) ?? null
      : null,
  };
}
function hiring(value: unknown, urls: Map<string, string>): unknown {
  if (value == null) return null;
  if (
    !object(value) || !uuid(value.id) || typeof value.skill !== "string" ||
    typeof value.message !== "string" ||
    typeof value.created_at !== "string" ||
    typeof value.expires_at !== "string" || !object(value.author)
  ) throw Error("server_unavailable");
  return {
    id: value.id,
    skill: value.skill,
    message: value.message,
    created_at: value.created_at,
    expires_at: value.expires_at,
    author: profile(value.author, urls),
  };
}

export async function handlePublicPreview(
  request: Request,
  database: Database,
  sign: Signer,
): Promise<Response> {
  if (request.method === "OPTIONS") {
    return new Response(null, { status: 204, headers: cors });
  }
  if (request.method !== "POST") {
    return reply(405, { code: "method_not_allowed" });
  }
  let parsed = false;
  try {
    const b = await bodyOf(request);
    parsed = true;
    const allowed: Record<string, string[]> = {
      profiles: ["query", "kind", "cursor"],
      names: ["query", "cursor"],
      profile: ["profile_id"],
      feed: ["cursor"],
      get: ["request_id"],
    };
    if (
      typeof b.action !== "string" || !Object.hasOwn(allowed, b.action) ||
      Object.keys(b).some((k) =>
        k !== "action" && !allowed[b.action as string].includes(k)
      )
    ) return reply(400, { code: "invalid_request" });
    if (
      b.query !== undefined &&
        (typeof b.query !== "string" || b.query.length > 200 ||
          b.query.includes("\0")) ||
      b.kind !== undefined &&
        !["all", "offering", "hiring"].includes(String(b.kind)) ||
      b.cursor != null && !object(b.cursor) ||
      b.action === "profile" && !uuid(b.profile_id) ||
      b.action === "get" && !uuid(b.request_id)
    ) return reply(400, { code: "invalid_request" });
    const source =
      request.headers.get("x-forwarded-for")?.split(",")[0].trim() ?? "unknown";
    const hash = [
      ...new Uint8Array(
        await crypto.subtle.digest("SHA-256", new TextEncoder().encode(source)),
      ),
    ].map((x) => x.toString(16).padStart(2, "0")).join("");
    for (
      const [bucket, limit] of [["preview:global", 3000], [
        "preview:" + hash,
        180,
      ]] as const
    ) {
      const budget = await database.rpc("invite_request_limit", {
        p_bucket: bucket,
        p_limit: limit,
        p_seconds: 60,
      });
      if (budget.error) return reply(503, { code: "server_unavailable" });
      if (!budget.data) return reply(429, { code: "rate_limited" });
    }
    const { data, error } = await database.rpc("public_preview", {
      p_action: b.action,
      p_query: b.query ?? "",
      p_kind: b.kind ?? "all",
      p_profile: b.profile_id ?? null,
      p_request: b.request_id ?? null,
      p_cursor: b.cursor ?? null,
      p_limit: 20,
    });
    if (error) {
      return reply(error.message === "invalid_request" ? 400 : 503, {
        code: error.message === "invalid_request"
          ? "invalid_request"
          : "server_unavailable",
      });
    }
    if (!object(data)) throw Error("server_unavailable");
    const profiles: unknown[] = [];
    if (Array.isArray(data.profiles)) profiles.push(...data.profiles);
    if (object(data.profile)) profiles.push(data.profile);
    if (Array.isArray(data.requests)) {
      for (const item of data.requests) {
        if (object(item)) profiles.push(item.author);
      }
    }
    if (object(data.request)) profiles.push(data.request.author);
    const paths = [
      ...new Set(
        profiles.filter(object).map((p) => p.avatar_path).filter((
          p,
        ): p is string =>
          typeof p === "string" && p.length > 0 && p.length <= 512 &&
          !p.startsWith("/") && !p.split("/").includes("..")
        ),
      ),
    ];
    const urls = paths.length ? await sign(paths) : new Map<string, string>();
    switch (b.action) {
      case "profile":
        return reply(200, { profile: profile(data.profile, urls) });
      case "get":
        return reply(200, { request: hiring(data.request, urls) });
      case "profiles":
      case "names":
        if (!Array.isArray(data.profiles) || data.profiles.length > 20) {
          throw Error("server_unavailable");
        }
        return reply(200, {
          query: data.query,
          kind: data.kind,
          profiles: data.profiles.map((p) => profile(p, urls)),
          next_cursor: data.next_cursor ?? null,
        });
      default:
        if (
          !Array.isArray(data.requests) || data.requests.length > 20 ||
          typeof data.server_now !== "string"
        ) throw Error("server_unavailable");
        return reply(200, {
          requests: data.requests.map((p) => hiring(p, urls)),
          next_cursor: data.next_cursor ?? null,
          server_now: data.server_now,
        });
    }
  } catch (e) {
    if (e instanceof Error && e.message === "request_too_large") {
      return reply(413, { code: "request_too_large" });
    }
    return reply(parsed ? 503 : 400, {
      code: parsed ? "server_unavailable" : "invalid_request",
    });
  }
}
