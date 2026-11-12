import { createClient } from "npm:@supabase/supabase-js@2.108.2";
import { handleSkillSearch } from "./handler.ts";

function check(value: boolean, description: string) {
  if (!value) throw new Error(description);
}
function fixture(options: {
  anonymous?: boolean;
  authFailure?: boolean;
  budget?: boolean;
  rpcError?: { message: string; code?: string };
} = {}) {
  const serviceCalls: string[] = [];
  const reads: { token: string; body: Record<string, unknown>; rpc: string }[] =
    [];
  const json = (data: unknown, status = 200) =>
    new Response(JSON.stringify(data), {
      status,
      headers: { "Content-Type": "application/json" },
    });
  const service = createClient("https://search-test.invalid", "service-key", {
    auth: { persistSession: false, autoRefreshToken: false },
    global: {
      fetch: (input) => {
        const url = String(input);
        serviceCalls.push(url);
        if (url.endsWith("/auth/v1/user")) {
          return Promise.resolve(
            options.authFailure
              ? json({ message: "invalid token" }, 401)
              : json({
                id: "10000000-0000-4000-8000-000000000001",
                is_anonymous: options.anonymous ?? false,
              }),
          );
        }
        check(
          url.endsWith("/invite_request_limit"),
          "Service never reads data",
        );
        return Promise.resolve(json(options.budget ?? true));
      },
    },
  });
  const userClient = (token: string) =>
    createClient("https://search-test.invalid", "public-key", {
      auth: { persistSession: false, autoRefreshToken: false },
      global: {
        headers: { Authorization: `Bearer ${token}` },
        fetch: (_input, init) => {
          check(
            new Headers(init?.headers).get("Authorization") ===
              `Bearer ${token}`,
            "Read RPC must carry this request's user JWT",
          );
          reads.push({
            token,
            body: JSON.parse(String(init?.body)),
            rpc: String(_input).split("/").pop()!,
          });
          return Promise.resolve(
            options.rpcError
              ? json(options.rpcError, 400)
              : json({ query: "marketing", results: [], next_cursor: null }),
          );
        },
      },
    });
  return { service, userClient, serviceCalls, reads };
}
function request(body: unknown, token = "test-session") {
  return new Request("https://search-test.invalid", {
    method: "POST",
    headers: { Authorization: `Bearer ${token}` },
    body: JSON.stringify(body),
  });
}

Deno.test("search uses request JWT and preserves raw query for SQL normalization", async () => {
  const f = fixture();
  const query = "\u00a0Digital\u2003Marketing\ufeff";
  const response = await handleSkillSearch(
    request({ action: "search", query }),
    f.service,
    f.userClient,
  );
  check(response.status === 200, "Search succeeds");
  check(f.reads[0].body.p_query === query, "SQL owns normalization");
  check(f.reads[0].body.p_cursor === null, "Default cursor absent");
  check(response.headers.get("Cache-Control") === "no-store", "No cache");
});
Deno.test("concurrent users keep independent immutable JWTs", async () => {
  const f = fixture();
  await Promise.all(["user-a", "user-b"].map((token) =>
    handleSkillSearch(
      request({ action: "suggest", query: "mar" }, token),
      f.service,
      f.userClient,
    )
  ));
  check(
    f.reads.map((r) => r.token).sort().join(",") === "user-a,user-b",
    "No cross-user token mutation",
  );
});
Deno.test("unverified, foreign and anonymous sessions cannot read", async () => {
  for (const options of [{ authFailure: true }, { anonymous: true }]) {
    const f = fixture(options);
    const response = await handleSkillSearch(
      request({ action: "suggest", query: "mar" }),
      f.service,
      f.userClient,
    );
    check(response.status === 401 && f.reads.length === 0, "Denied before RPC");
  }
});
Deno.test("strict requests reject spoofed actors, ID lists and malformed inputs", async () => {
  for (
    const body of [
      { action: "search", query: "mar", actor: "other" },
      { action: "search", query: "mar", allowed_ids: [] },
      { action: "search", query: "mar", kind: ["all"] },
      { action: "search", query: "mar", kind: "global" },
      { action: "search", query: "mar", limit: 0 },
      { action: "search", query: "mar", limit: 51 },
      { action: "search", query: "mar", limit: 1.5 },
      { action: "search", query: "mar", cursor: [] },
      { action: "suggest", query: "mar", cursor: null },
      { action: "search", query: "\0" },
      { action: "search", query: "   " },
      { action: "search", query: "x".repeat(32769) },
      { action: "other", query: "mar" },
      [],
    ]
  ) {
    const f = fixture();
    const response = await handleSkillSearch(
      request(body),
      f.service,
      f.userClient,
    );
    check(response.status === 400 && !f.reads.length, "Malformed input denied");
  }
});
Deno.test("authorization and server failures remain errors, never empty results", async () => {
  for (
    const [rpcError, status, code] of [
      [{ message: "membership_required" }, 403, "membership_required"],
      [{ message: "invalid_request" }, 400, "invalid_request"],
      [{ message: "internal table details" }, 503, "server_unavailable"],
      [{ message: "expired", code: "PGRST301" }, 401, "sign_in_required"],
    ] as const
  ) {
    const f = fixture({ rpcError });
    const response = await handleSkillSearch(
      request({ action: "search", query: "mar" }),
      f.service,
      f.userClient,
    );
    check(response.status === status, "HTTP error status preserved");
    check((await response.json()).code === code, "Safe error code");
  }
});
Deno.test("rate budget stops reads and oversized streams are cancelled", async () => {
  const f = fixture({ budget: false });
  const limited = await handleSkillSearch(
    request({ action: "search", query: "mar" }),
    f.service,
    f.userClient,
  );
  check(limited.status === 429 && !f.reads.length, "Budget enforced");
  let cancelled = false;
  const stream = new ReadableStream({
    pull(controller) {
      controller.enqueue(new Uint8Array(20000));
    },
    cancel() {
      cancelled = true;
    },
  });
  const large = await handleSkillSearch(
    new Request("https://search-test.invalid", {
      method: "POST",
      headers: { Authorization: "Bearer test-session" },
      body: stream,
    }),
    f.service,
    f.userClient,
  );
  check(large.status === 413 && cancelled, "Streaming bytes bounded");
});

Deno.test("name search uses the captured user JWT and distinct RPC without skill kind", async () => {
  const f = fixture();
  const cursor = {
    query: "julia",
    mode: "names",
    rank: 0,
    name: "julia",
    after: "75000000-0000-4000-8000-000000000002",
  };
  const response = await handleSkillSearch(
    request({ action: "search_names", query: "Julia", cursor }),
    f.service,
    f.userClient,
  );
  check(response.status === 200, "Names succeed");
  check(f.reads[0].rpc === "profile_name_search", "Name RPC");
  check(!Object.hasOwn(f.reads[0].body, "p_kind"), "No skill kind");
  check(f.reads[0].body.p_query === "Julia", "Raw literal query");
  check(
    JSON.stringify(f.reads[0].body.p_cursor) === JSON.stringify(cursor),
    "Cursor passed",
  );
});
Deno.test("name request rejects short queries, skill modes and spoofed viewer", async () => {
  for (
    const body of [{ action: "search_names", query: "x" }, {
      action: "search_names",
      query: "Julia",
      kind: "hiring",
    }, { action: "search_names", query: "Julia", viewer: "other" }]
  ) {
    const f = fixture();
    const r = await handleSkillSearch(request(body), f.service, f.userClient);
    check(r.status === 400 && f.reads.length === 0, "Rejected before reads");
  }
});

Deno.test("session and membership failures retain authentication status for both searches", async () => {
  for (const action of ["search", "search_names"]) {
    for (
      const [message, status] of [["session_revoked", 401], [
        "membership_required",
        403,
      ]] as const
    ) {
      const f = fixture({ rpcError: { message, code: "42501" } });
      const r = await handleSkillSearch(
        request({ action, query: "Julia" }),
        f.service,
        f.userClient,
      );
      check(r.status === status, "Not a generic503");
      check((await r.json()).code === message, "Preserve error code");
    }
  }
});
