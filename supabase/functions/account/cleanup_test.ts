import { assert, assertEquals } from "jsr:@std/assert@1.0.19";
import { createClient } from "npm:@supabase/supabase-js@2.108.2";
import { cleanupDeletions } from "./cleanup.ts";
import { handleAccount } from "./handler.ts";
import { handleMaintenance } from "../maintenance/handler.ts";

const actor = "72000000-0000-4000-8000-000000000001";
const session = "72100000-0000-4000-8000-000000000001";
const operation = "72200000-0000-4000-8000-000000000001";
const token = "a".repeat(64);
const bearer = "unit." + btoa(JSON.stringify({ session_id: session })) +
  ".signature";
const secret = "maintenance-unit-private-bearer-" + "x".repeat(20);
const proof = Array.from(
  new Uint8Array(
    await crypto.subtle.digest("SHA-256", new TextEncoder().encode(token)),
  ),
  (byte) => byte.toString(16).padStart(2, "0"),
).join("");

function fixture() {
  const state = {
    job: false,
    complete: false,
    leased: false,
    lease: "",
    authPresent: true,
    storageFail: false,
    authFail: false,
    authUnknownCommit: false,
    staleFence: false,
    missingCommunity: false,
    communityFail: false,
    authReads: 0,
    authDeletes: [] as string[],
    files: [{ bucket: "avatars", name: actor + "/photo.png" }],
    calls: [] as { name: string; body: Record<string, unknown> }[],
  };
  const status = () => ({
    operation_id: operation,
    state: state.complete ? "complete" : "pending",
  });
  const database = createClient(
    "https://deletion-test.invalid",
    "unit-service-key",
    {
      auth: { persistSession: false, autoRefreshToken: false },
      global: {
        fetch: async (input, init) => {
          const url = new URL(String(input));
          if (url.pathname === "/auth/v1/user") {
            state.authReads++;
            return Response.json(
              state.authPresent
                ? { id: actor, is_anonymous: false }
                : { message: "User gone" },
              { status: state.authPresent ? 200 : 401 },
            );
          }
          if (url.pathname.startsWith("/auth/v1/admin/users/")) {
            state.authDeletes.push(url.pathname.split("/").pop()!);
            if (state.authUnknownCommit) {
              state.authPresent = false;
              state.authUnknownCommit = false;
              return Response.json({ message: "Unknown commit" }, {
                status: 503,
              });
            }
            if (state.authFail) {
              return Response.json({ message: "Auth unavailable" }, {
                status: 503,
              });
            }
            const existed = state.authPresent;
            state.authPresent = false;
            return Response.json(
              existed ? { id: actor } : { message: "User not found" },
              { status: existed ? 200 : 404 },
            );
          }
          if (url.pathname.startsWith("/storage/v1/object/")) {
            if (state.storageFail) {
              return Response.json({
                message: "Storage unavailable",
                statusCode: "503",
              }, { status: 503 });
            }
            state.files = [];
            return Response.json([]);
          }
          const name = url.pathname.split("/").pop()!;
          const body = JSON.parse(String(init?.body ?? "{}"));
          state.calls.push({ name, body });
          if (name === "invite_request_limit") return Response.json(true);
          if (name === "account_deletion_status") {
            return Response.json(
              state.job && body.p_operation === operation &&
                body.p_receipt_hash === proof
                ? status()
                : null,
            );
          }
          if (name === "member_delete_account") {
            state.job = true;
            return Response.json(status());
          }
          if (name === "community_expire") {
            if (state.missingCommunity) {
              return Response.json({
                code: "PGRST202",
                message: "Module pending",
              }, { status: 404 });
            }
            if (state.communityFail) {
              return Response.json(
                { code: "P0001", message: "Expiry failed" },
                { status: 500 },
              );
            }
            return Response.json(2);
          }
          if (name === "avatar_cleanup_claim") return Response.json([]);
          if (name === "account_cleanup_claim") {
            if (
              !state.job || state.complete || state.leased ||
              (body.p_operation != null && body.p_operation !== operation)
            ) return Response.json([]);
            state.leased = true;
            state.lease = crypto.randomUUID();
            return Response.json([{
              operation_id: operation,
              lease_token: state.lease,
            }]);
          }
          if (name === "account_cleanup_prepare") {
            return Response.json(
              state.staleFence || body.p_lease !== state.lease
                ? null
                : { objects: state.files, auth_user_id: actor },
            );
          }
          if (name === "account_cleanup_finish") {
            if (body.p_lease !== state.lease) return Response.json(null);
            state.leased = false;
            state.complete = body.p_success === true && !state.authPresent &&
              state.files.length === 0;
            return Response.json(status());
          }
          throw new Error("Unexpected fixture API");
        },
      },
    },
  );
  return { state, database };
}
function request(body: unknown, authenticated = true) {
  return new Request("https://deletion-test.invalid", {
    method: "POST",
    headers: authenticated ? { Authorization: "Bearer " + bearer } : {},
    body: JSON.stringify(body),
  });
}
const deletion = {
  action: "delete",
  expected_user_id: actor,
  client_operation_id: operation,
  confirm: true,
  receipt_token: token,
};
const recovery = {
  action: "deletion_status",
  client_operation_id: operation,
  receipt_token: token,
};

Deno.test("cancelled confirmation and changed identity cannot start deletion", async () => {
  for (
    const body of [{ ...deletion, confirm: false }, {
      ...deletion,
      expected_user_id: "72000000-0000-4000-8000-000000000002",
    }]
  ) {
    const { database, state } = fixture();
    const response = await handleAccount(request(body), database);
    assert([400, 409].includes(response.status));
    assertEquals(state.job, false);
    assertEquals(state.authPresent, true);
    assertEquals(state.authDeletes.length, 0);
  }
});
Deno.test("confirmed deletion removes Storage before hard Auth delete and supports lost-ACK recovery without JWT", async () => {
  const { database, state } = fixture();
  const response = await handleAccount(request(deletion), database);
  assertEquals(response.status, 200);
  assertEquals(await response.json(), {
    operation_id: operation,
    state: "complete",
  });
  assertEquals(state.files.length, 0);
  assertEquals(state.authDeletes, [actor]);
  const reads = state.authReads;
  const recovered = await handleAccount(request(recovery, false), database);
  assertEquals(await recovered.json(), {
    operation_id: operation,
    state: "complete",
  });
  const retried = await handleAccount(request(deletion, false), database);
  assertEquals(retried.status, 200);
  assertEquals(state.authReads, reads);
  assertEquals(state.authDeletes, [actor]);
});
Deno.test("Storage outage leaves durable pending status and never deletes Auth first", async () => {
  const { database, state } = fixture();
  state.storageFail = true;
  const response = await handleAccount(request(deletion), database);
  assertEquals(await response.json(), {
    operation_id: operation,
    state: "pending",
  });
  assertEquals(state.authDeletes.length, 0);
  const recovered = await handleAccount(request(recovery, false), database);
  assertEquals(recovered.status, 200);
  assertEquals((await recovered.json()).state, "pending");
  state.storageFail = false;
  const result = await cleanupDeletions(database);
  assertEquals(result.complete, 1);
});
Deno.test("unconfirmed Auth commit retries the same target through an idempotent Auth404", async () => {
  const { database, state } = fixture();
  state.job = true;
  state.files = [];
  state.authUnknownCommit = true;
  assertEquals((await cleanupDeletions(database)).retry, 1);
  assertEquals((await cleanupDeletions(database)).complete, 1);
  assertEquals(state.authDeletes, [actor, actor]);
});
Deno.test("stale fence discloses no cleanup object and performs no external mutation", async () => {
  const { database, state } = fixture();
  state.job = true;
  state.staleFence = true;
  assertEquals((await cleanupDeletions(database)).cancelled, 1);
  assertEquals(state.files.length, 1);
  assertEquals(state.authDeletes.length, 0);
});
Deno.test("wrong and unknown receipts have identical unavailable responses", async () => {
  const { database, state } = fixture();
  state.job = true;
  for (
    const body of [{ ...recovery, receipt_token: "b".repeat(64) }, {
      ...recovery,
      client_operation_id: "72200000-0000-4000-8000-000000000002",
    }]
  ) {
    const response = await handleAccount(request(body, false), database);
    assertEquals(response.status, 404);
    assertEquals(await response.json(), { code: "deletion_unavailable" });
  }
  assertEquals(state.authReads, 0);
});
Deno.test("maintenance private bearer guards both expiry and deletion jobs", async () => {
  const { database, state } = fixture();
  state.job = true;
  const denied = await handleMaintenance(request({}), database, secret);
  assertEquals(denied.status, 401);
  assertEquals(state.calls.length, 0);
  const response = await handleMaintenance(
    new Request("https://deletion-test.invalid", {
      method: "POST",
      headers: { Authorization: "Bearer " + secret },
      body: "{}",
    }),
    database,
    secret,
  );
  assertEquals(response.status, 200);
  const result = await response.json();
  assertEquals(result.community_expired, 2);
  assertEquals(result.cleanup.complete, 1);
});
Deno.test("maintenance completes deletions during staged Community installation", async () => {
  const { database, state } = fixture();
  state.job = true;
  state.missingCommunity = true;
  const response = await handleMaintenance(
    new Request("https://deletion-test.invalid", {
      method: "POST",
      headers: { Authorization: "Bearer " + secret },
      body: "{}",
    }),
    database,
    secret,
  );
  assertEquals(response.status, 200);
  assertEquals((await response.json()).community_pending, true);
  assertEquals(state.complete, true);
});
