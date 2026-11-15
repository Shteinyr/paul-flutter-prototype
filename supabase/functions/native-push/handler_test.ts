import { strict as assert } from "node:assert";
import type { PushDatabase } from "../push/shared.ts";
import { handleNativePush } from "./handler.ts";
const actor = "15000000-0000-4000-8000-000000000001",
  session = "15000000-0000-4000-8000-000000000002",
  binding = "15000000-0000-4000-8000-000000000003";
const bearer = "test." + btoa(JSON.stringify({ session_id: session })) +
  ".signature";
function fixture(failure?: string) {
  const calls: { name: string; args: Record<string, unknown> }[] = [];
  const database = {
    auth: {
      getUser: () =>
        Promise.resolve({
          data: { user: { id: actor, is_anonymous: false } },
          error: null,
        }),
    },
    rpc: (name: string, args: Record<string, unknown>) => {
      calls.push({ name, args });
      if (name === "invite_request_limit") {
        return Promise.resolve({
          data: true,
          error: null,
        });
      }
      return Promise.resolve(
        failure ? { data: null, error: { message: failure } } : {
          data: {
            recipient_user_id: actor,
            session_id: session,
            binding_id: binding,
            enabled: true,
          },
          error: null,
        },
      );
    },
  } as unknown as PushDatabase;
  const request = (body: unknown, token: string | null = bearer) =>
    new Request("https://test.invalid/native-push", {
      method: "POST",
      headers: token ? { Authorization: "Bearer " + token } : {},
      body: JSON.stringify(body),
    });
  return { calls, database, request };
}
Deno.test("native binding captures verified identity/session, hashes token and accepts no spoofed actor", async () => {
  const f = fixture();
  const body = {
    action: "subscribe",
    binding_id: binding,
    token: "device-capability-12345678901234567890",
    platform: "ios",
  };
  assert.equal(
    (await handleNativePush(
      f.request({ ...body, p_user: "spoof" }),
      f.database,
    )).status,
    400,
  );
  assert.equal(f.calls.length, 0);
  const response = await handleNativePush(f.request(body), f.database);
  assert.equal(response.status, 200);
  const call = f.calls.at(-1)!;
  assert.equal(call.name, "native_push_subscribe");
  assert.equal(call.args.p_user, actor);
  assert.equal(call.args.p_session, session);
  assert.match(call.args.p_token_hash as string, /^[a-f0-9]{64}$/);
  assert.notEqual(call.args.p_token_hash, body.token);
  const result = await response.json();
  assert.equal(result.token, undefined);
});
Deno.test("unadmitted session is rejected by the server gate", async () => {
  const f = fixture("session_admission_required");
  const response = await handleNativePush(
    f.request({ action: "unsubscribe", binding_id: binding }),
    f.database,
  );
  assert.equal(response.status, 403);
  assert.deepEqual(await response.json(), {
    code: "session_admission_required",
  });
});
Deno.test("missing/invalid Auth and malformed/oversized native requests fail closed", async () => {
  const f = fixture();
  assert.equal(
    (await handleNativePush(f.request({}, null), f.database)).status,
    401,
  );
  assert.equal(
    (await handleNativePush(f.request({}, "bad"), f.database)).status,
    401,
  );
  const malformed = new Request("https://test.invalid", {
    method: "POST",
    headers: { Authorization: "Bearer " + bearer },
    body: "{",
  });
  assert.equal((await handleNativePush(malformed, f.database)).status, 400);
  const huge = f.request({
    action: "subscribe",
    binding_id: binding,
    token: "a".repeat(9000),
    platform: "ios",
  });
  assert.equal((await handleNativePush(huge, f.database)).status, 413);
  assert.equal(f.calls.length, 0);
});
Deno.test("unknown RPC errors never expose SQL or provider credentials", async () => {
  const f = fixture("private diagnostics must not leave the server");
  const response = await handleNativePush(
    f.request({ action: "unsubscribe", binding_id: binding }),
    f.database,
  );
  assert.equal(response.status, 503);
  assert.deepEqual(await response.json(), { code: "server_unavailable" });
});
