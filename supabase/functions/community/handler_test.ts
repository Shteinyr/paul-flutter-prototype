import { assertEquals } from "jsr:@std/assert@1.0.19";
import { createClient } from "npm:@supabase/supabase-js@2.108.2";
import { handleCommunity } from "./handler.ts";

const actor = "47000000-0000-4000-8000-000000000001";
const session = "47100000-0000-4000-8000-000000000001";
const operation = "47200000-0000-4000-8000-000000000001";
const requestId = "47300000-0000-4000-8000-000000000001";
const bearer = "e30." +
  btoa(JSON.stringify({ sub: actor, session_id: session })).replaceAll(
    "=",
    "",
  ) + ".signature";

function database(result: unknown = {}, failure?: string, budget = true) {
  const calls: { name: string; body: Record<string, unknown> }[] = [];
  const client = createClient("https://community-unit.invalid", "unit-key", {
    auth: { persistSession: false, autoRefreshToken: false },
    global: {
      fetch: (input, init) => {
        const path = new URL(String(input)).pathname;
        if (path.endsWith("/auth/v1/user")) {
          return Promise.resolve(
            Response.json({ id: actor, is_anonymous: false }),
          );
        }
        const name = path.split("/").pop()!;
        calls.push({ name, body: JSON.parse(String(init?.body)) });
        if (name === "invite_request_limit") {
          return Promise.resolve(Response.json(budget));
        }
        return Promise.resolve(
          failure
            ? Response.json({ message: failure, code: "P0001" }, {
              status: 400,
            })
            : Response.json(result),
        );
      },
    },
  });
  return { client, calls };
}

function request(body: unknown, token: string | null = bearer) {
  return new Request("https://community-unit.invalid/community", {
    method: "POST",
    headers: token ? { Authorization: "Bearer " + token } : {},
    body: JSON.stringify(body),
  });
}

Deno.test("Community guards methods and unsigned requests before commands", async () => {
  const db = database();
  assertEquals(
    (await handleCommunity(
      new Request("https://unit.invalid", { method: "OPTIONS" }),
      db.client,
    )).status,
    204,
  );
  assertEquals(
    (await handleCommunity(new Request("https://unit.invalid"), db.client))
      .status,
    405,
  );
  assertEquals(
    (await handleCommunity(request({ action: "feed" }, null), db.client))
      .status,
    401,
  );
  assertEquals(db.calls.length, 0);
});

Deno.test("Community create derives actor/session and accepts grapheme-safe Unicode", async () => {
  const db = database({
    request_id: requestId,
    state: "active",
    replayed: false,
  });
  const message = "👨‍👩‍👦".repeat(2000);
  const response = await handleCommunity(
    request({
      action: "create",
      client_operation_id: operation,
      skill: " Product   Design ",
      message,
    }),
    db.client,
  );
  assertEquals(response.status, 200);
  assertEquals(db.calls[1], {
    name: "community_create",
    body: {
      p_user: actor,
      p_session: session,
      p_operation: operation,
      p_skill: "Product Design",
      p_message: message,
    },
  });
  assertEquals(response.headers.get("cache-control"), "no-store");
});

Deno.test("Community rejects spoofed ownership, wrong fields and invalid input", async () => {
  for (
    const [body, code] of [
      [{ action: "feed", p_user: actor }, "invalid_request"],
      [{
        action: "create",
        client_operation_id: operation,
        skill: "x".repeat(65),
        message: "Help",
      }, "invalid_skill"],
      [{
        action: "create",
        client_operation_id: operation,
        skill: "Design",
        message: "x".repeat(2001),
      }, "invalid_message"],
      [{
        action: "create",
        client_operation_id: operation,
        skill: "Design",
        message: " \n ",
      }, "invalid_message"],
      [{
        action: "close",
        client_operation_id: operation,
        request_id: "not-a-uuid",
      }, "invalid_request"],
      [
        { action: "feed", cursor: { id: requestId, created_at: "invalid" } },
        "invalid_request",
      ],
    ] as const
  ) {
    const db = database();
    const response = await handleCommunity(request(body), db.client);
    assertEquals(response.status, 400);
    assertEquals(await response.json(), { code });
    assertEquals(db.calls.length, 0);
  }
});

Deno.test("Community requires a verified session claim", async () => {
  const db = database();
  const token = "e30." + btoa(JSON.stringify({ sub: actor })) + ".signature";
  assertEquals(
    (await handleCommunity(request({ action: "feed" }, token), db.client))
      .status,
    401,
  );
  assertEquals(db.calls.length, 0);
});

Deno.test("Community maps current membership, level and operation failures", async () => {
  for (
    const [failure, status] of [
      ["community_locked", 403],
      ["community_forbidden", 403],
      ["session_revoked", 401],
      ["operation_id_conflict", 409],
    ] as const
  ) {
    const db = database({}, failure);
    const response = await handleCommunity(
      request({
        action: "close",
        request_id: requestId,
        client_operation_id: operation,
      }),
      db.client,
    );
    assertEquals(response.status, status);
    assertEquals(await response.json(), { code: failure });
  }
});

Deno.test("Community read and pagination preserve unavailable state and bounded cursors", async () => {
  const unavailable = database({ request: null, state: "unavailable" });
  const response = await handleCommunity(
    request({ action: "get", request_id: requestId }),
    unavailable.client,
  );
  assertEquals(await response.json(), { request: null, state: "unavailable" });
  const db = database({ requests: [], next_cursor: null });
  const cursor = { created_at: "2026-11-11T02:00:00Z", id: requestId };
  assertEquals(
    (await handleCommunity(
      request({ action: "feed", cursor, limit: 2 }),
      db.client,
    )).status,
    200,
  );
  assertEquals(db.calls[1].body, {
    p_user: actor,
    p_session: session,
    p_cursor: cursor,
    p_limit: 2,
  });
});

Deno.test("Community transport budget stops work before request mutation", async () => {
  const db = database({}, undefined, false);
  assertEquals(
    (await handleCommunity(request({ action: "feed" }), db.client)).status,
    429,
  );
  assertEquals(db.calls.length, 1);
});

Deno.test("Community bounds streamed bytes and rejects malformed JSON", async () => {
  const db = database();
  let cancelled = false;
  const stream = new ReadableStream({
    start(controller) {
      controller.enqueue(new Uint8Array(100001));
    },
    cancel() {
      cancelled = true;
    },
  });
  const oversized = new Request("https://unit.invalid", {
    method: "POST",
    headers: { Authorization: "Bearer " + bearer },
    body: stream,
  });
  assertEquals((await handleCommunity(oversized, db.client)).status, 413);
  assertEquals(cancelled, true);
  const malformed = new Request("https://unit.invalid", {
    method: "POST",
    headers: { Authorization: "Bearer " + bearer },
    body: "{",
  });
  assertEquals((await handleCommunity(malformed, db.client)).status, 400);
  assertEquals(db.calls.length, 0);
});
