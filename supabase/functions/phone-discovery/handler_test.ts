import { assertEquals } from "jsr:@std/assert@1.0.19";
import { createClient } from "npm:@supabase/supabase-js@2.108.2";
import { handlePhoneDiscovery, normalizePhone } from "./handler.ts";

const actor = "70000000-0000-4000-8000-000000000001";
const session = "70100000-0000-4000-8000-000000000001";
const other = "70000000-0000-4000-8000-000000000002";
const bearer = "unit." + btoa(JSON.stringify({ session_id: session })) +
  ".signature";
function fixture(options: {
  error?: string;
  authStatus?: number;
  anonymous?: boolean;
  allowed?: boolean;
} = {}) {
  const calls: { name: string; body: Record<string, unknown> }[] = [];
  const database = createClient("https://phone-test.invalid", "unit-key", {
    auth: { persistSession: false, autoRefreshToken: false },
    global: {
      fetch: async (input, init) => {
        const name = new URL(String(input)).pathname.split("/").pop()!;
        if (name === "user") {
          return Response.json(
            options.authStatus ? { message: "Auth unavailable" } : {
              id: actor,
              is_anonymous: options.anonymous ?? false,
              user_metadata: { phone: "+12025550101", phone_verified: true },
            },
            { status: options.authStatus ?? 200 },
          );
        }
        calls.push({ name, body: JSON.parse(String(init?.body)) });
        if (name === "invite_request_limit") {
          return Response.json(options.allowed ?? true);
        }
        if (options.error) {
          return Response.json({ message: options.error, code: "P0001" }, {
            status: 400,
          });
        }
        return Response.json(
          name === "phone_discovery_lookup"
            ? { matches: [{ index: 1, profile_id: other }] }
            : {
              has_verified_phone: true,
              phone_last4: "0101",
              phone_revision: "a".repeat(64),
              discoverable: false,
            },
        );
      },
    },
  });
  return { database, calls };
}
function request(body: unknown, authorization = "Bearer " + bearer) {
  return new Request("https://phone-test.invalid", {
    method: "POST",
    headers: { Authorization: authorization },
    body: JSON.stringify({ expected_user_id: actor, ...body as object }),
  });
}
Deno.test("phone normalization uses explicit country, strict full input and validated E164", () => {
  assertEquals(normalizePhone(" +1 (202) 555-0101 "), "+12025550101");
  assertEquals(normalizePhone("020 7946 0018", "GB"), "+442079460018");
  assertEquals(normalizePhone("020 7946 0018"), null);
  assertEquals(normalizePhone("Call +1 202 555 0101"), null);
  assertEquals(normalizePhone("+1 202 555 0101 ext 5"), null);
  assertEquals(normalizePhone("+10000000000"), null);
});
Deno.test("status pins verified identity and session without copying editable phone metadata", async () => {
  const { database, calls } = fixture();
  const result = await handlePhoneDiscovery(
    request({ action: "status" }),
    database,
  );
  assertEquals(result.status, 200);
  assertEquals(calls[1], {
    name: "phone_discovery_status",
    body: { p_user: actor, p_session: session },
  });
  assertEquals(result.headers.get("Cache-Control"), "no-store");
});
Deno.test("a switched identity cannot apply a previous account's phone consent or lookup", async () => {
  for (const action of ["status", "consent", "lookup"]) {
    const { database, calls } = fixture();
    const result = await handlePhoneDiscovery(
      request({
        action,
        expected_user_id: other,
        ...(action === "consent"
          ? { enabled: true, expected_phone_revision: "a".repeat(64) }
          : {}),
        ...(action === "lookup" ? { phones: ["+12025550101"] } : {}),
      }),
      database,
    );
    assertEquals(result.status, 409);
    assertEquals(await result.json(), { code: "identity_changed" });
    assertEquals(calls, []);
  }
});
Deno.test("lookup preserves selected indexes and sends only normalized numbers to SQL", async () => {
  const { database, calls } = fixture();
  const result = await handlePhoneDiscovery(
    request({
      action: "lookup",
      phones: ["invalid", "020 7946 0018", "+1 (202) 555-0101"],
      default_country: "GB",
    }),
    database,
  );
  assertEquals(result.status, 200);
  assertEquals(calls[1], {
    name: "phone_discovery_lookup",
    body: {
      p_user: actor,
      p_session: session,
      p_phones: [null, "+442079460018", "+12025550101"],
    },
  });
  assertEquals(await result.json(), {
    matches: [{ index: 1, profile_id: other }],
    invalid_indexes: [0],
  });
});
Deno.test("consent requires the phone revision while withdrawal works after the number changes", async () => {
  const { database, calls } = fixture();
  assertEquals(
    (await handlePhoneDiscovery(
      request({ action: "consent", enabled: true }),
      database,
    )).status,
    400,
  );
  assertEquals(calls.length, 0);
  await handlePhoneDiscovery(
    request({
      action: "consent",
      enabled: true,
      expected_phone_revision: "b".repeat(64),
    }),
    database,
  );
  assertEquals(calls[1].body.p_expected_revision, "b".repeat(64));
  await handlePhoneDiscovery(
    request({ action: "consent", enabled: false }),
    database,
  );
  assertEquals(calls[3].body.p_expected_revision, null);
  assertEquals(calls[3].body.p_enabled, false);
});
Deno.test("oversized, forged and malformed selections cannot invoke privileged SQL", async () => {
  for (
    const body of [
      { action: "status", phone: "+12025550101" },
      { action: "lookup", phones: [] },
      { action: "lookup", phones: Array(51).fill("+12025550101") },
      { action: "lookup", phones: [{}] },
      { action: "lookup", phones: ["1".repeat(129)] },
      { action: "lookup", phones: ["+12025550101"], default_country: "XX" },
    ]
  ) {
    const { database, calls } = fixture();
    assertEquals(
      (await handlePhoneDiscovery(request(body), database)).status,
      400,
    );
    assertEquals(calls, []);
  }
});
Deno.test("verification, phone changes, session revocation and rate errors remain actionable", async () => {
  for (
    const [error, status] of [
      ["phone_verification_required", 403],
      ["phone_changed", 409],
      ["session_revoked", 401],
      ["membership_required", 403],
      ["rate_limited", 429],
      ["Private SQL internals", 503],
    ] as const
  ) {
    const { database } = fixture({ error });
    const result = await handlePhoneDiscovery(
      request({ action: "status" }),
      database,
    );
    assertEquals(result.status, status);
    assertEquals(await result.json(), {
      code: status === 503 ? "server_unavailable" : error,
    });
  }
});
Deno.test("missing, anonymous and failed Auth never reaches discovery SQL", async () => {
  for (
    const [options, status] of [
      [{ anonymous: true }, 401],
      [{ authStatus: 401 }, 401],
      [{ authStatus: 503 }, 503],
    ] as const
  ) {
    const { database, calls } = fixture(options);
    assertEquals(
      (await handlePhoneDiscovery(request({ action: "status" }), database))
        .status,
      status,
    );
    assertEquals(calls, []);
  }
  const { database, calls } = fixture({ allowed: false });
  assertEquals(
    (await handlePhoneDiscovery(request({ action: "status" }), database))
      .status,
    429,
  );
  assertEquals(calls.length, 1);
});
