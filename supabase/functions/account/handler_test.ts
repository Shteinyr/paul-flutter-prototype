import { assert, assertEquals } from "jsr:@std/assert@1.0.19";
import { createClient } from "npm:@supabase/supabase-js@2.108.2";
import { handleAccount } from "./handler.ts";

const actor = "86000000-0000-4000-8000-000000000001";
const session = "86100000-0000-4000-8000-000000000001";
const peer = "86000000-0000-4000-8000-000000000002";
const bearer = "unit." +
  btoa(JSON.stringify({ session_id: session, sub: peer })) + ".signature";
const capabilities = {
  invited_registrations: 1,
  can_message_anyone: false,
  can_publish_community: false,
  offering_limit: 5,
  new_conversations_remaining: 1,
  quota_resets_at: "2026-11-12T00:00:00Z",
};
function fixture(
  options: {
    error?: string;
    authStatus?: number;
    anonymous?: boolean;
    allowed?: boolean;
  } = {},
) {
  const calls: { name: string; body: Record<string, unknown> }[] = [];
  const database = createClient("https://account-test.invalid", "unit-key", {
    auth: { persistSession: false, autoRefreshToken: false },
    global: {
      fetch: async (input, init) => {
        const name = new URL(String(input)).pathname.split("/").pop()!;
        if (name === "user") {
          return Response.json(
            options.authStatus
              ? { message: "Auth failed" }
              : { id: actor, is_anonymous: options.anonymous ?? false },
            { status: options.authStatus ?? 200 },
          );
        }
        calls.push({ name, body: JSON.parse(String(init?.body)) });
        if (name === "invite_request_limit") {
          return Response.json(options.allowed ?? true);
        }
        if (options.error) {
          return Response.json({
            code: "P0001",
            message: options.error,
            details: "Internal SQL details",
          }, { status: 400 });
        }
        return Response.json(
          name === "member_profile"
            ? { profile: { id: peer, contact_count: 3 } }
            : capabilities,
        );
      },
    },
  });
  return { database, calls };
}
function request(body: unknown) {
  return new Request("https://account-test.invalid", {
    method: "POST",
    headers: { Authorization: "Bearer " + bearer },
    body: JSON.stringify(body),
  });
}
Deno.test("capabilities use the verified Auth actor and live session, never a JWT subject as caller", async () => {
  const { database, calls } = fixture();
  const response = await handleAccount(
    request({ action: "capabilities" }),
    database,
  );
  assertEquals(response.status, 200);
  assertEquals(await response.json(), capabilities);
  assertEquals(calls[1], {
    name: "member_capabilities",
    body: { p_user: actor, p_session: session },
  });
  assertEquals(response.headers.get("Cache-Control"), "no-store");
});
Deno.test("global profile reads preserve profile id and return server contact count", async () => {
  const { database, calls } = fixture();
  const response = await handleAccount(
    request({ action: "profile", profile_id: peer }),
    database,
  );
  assertEquals(response.status, 200);
  assertEquals(await response.json(), {
    profile: { id: peer, contact_count: 3 },
  });
  assertEquals(calls[1].body, {
    p_user: actor,
    p_session: session,
    p_profile: peer,
  });
});
Deno.test("revoked sessions, missing membership and unavailable profiles remain distinct failures", async () => {
  for (
    const [error, status] of [["session_revoked", 401], [
      "membership_required",
      403,
    ], ["profile_unavailable", 404]] as const
  ) {
    const { database } = fixture({ error });
    const response = await handleAccount(
      request({ action: "profile", profile_id: peer }),
      database,
    );
    assertEquals(response.status, status);
    assertEquals(await response.json(), { code: error });
  }
});
Deno.test("anonymous and unverified Auth identities cannot invoke member RPCs", async () => {
  for (const options of [{ anonymous: true }, { authStatus: 401 }]) {
    const { database, calls } = fixture(options);
    const response = await handleAccount(
      request({ action: "capabilities" }),
      database,
    );
    assertEquals(response.status, 401);
    assertEquals(calls.length, 0);
  }
});
Deno.test("actor overrides, malformed profiles and unknown actions are rejected before service RPCs", async () => {
  for (
    const body of [
      { action: "capabilities", user_id: peer },
      { action: "profile", profile_id: "bad" },
      { action: "delete", confirm: true },
      { action: "toString" },
    ]
  ) {
    const { database, calls } = fixture();
    const response = await handleAccount(request(body), database);
    assertEquals(response.status, 400);
    assertEquals(calls.length, 0);
  }
});
Deno.test("oversized chunked requests cancel reading before member RPCs", async () => {
  const { database, calls } = fixture();
  let cancelled = false;
  const body = new ReadableStream({
    pull(controller) {
      controller.enqueue(new Uint8Array(20000));
    },
    cancel() {
      cancelled = true;
    },
  });
  const response = await handleAccount(
    new Request("https://account-test.invalid", {
      method: "POST",
      headers: { Authorization: "Bearer " + bearer },
      body,
    }),
    database,
  );
  assertEquals(response.status, 413);
  assert(cancelled);
  assertEquals(calls.length, 0);
});
Deno.test("request budgets and transient errors do not become empty member data", async () => {
  const limited = fixture({ allowed: false });
  assertEquals(
    (await handleAccount(request({ action: "capabilities" }), limited.database))
      .status,
    429,
  );
  assertEquals(limited.calls.length, 1);
  const failed = fixture({ error: "Unknown internal SQL" });
  const response = await handleAccount(
    request({ action: "capabilities" }),
    failed.database,
  );
  assertEquals(response.status, 503);
  assertEquals(await response.json(), { code: "server_unavailable" });
});
