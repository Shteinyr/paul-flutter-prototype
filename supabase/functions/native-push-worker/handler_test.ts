import { strict as assert } from "node:assert";
import type { PushDatabase } from "../push/shared.ts";
import { handleNativePushWorker } from "./handler.ts";
import type { NativePreparedPush } from "./transport.ts";

const secret = "worker-test-secret-12345678901234567890";
const claims = [1, 2].map((n) => ({
  delivery_id: `15000000-0000-4000-8000-00000000000${n}`,
  lease_token: `15100000-0000-4000-8000-00000000000${n}`,
}));
const prepared = {
  token: "test-firebase-installation-id",
  platform: "ios" as const,
  lease_remaining_ms: 30000,
  payload: {
    version: 1 as const,
    delivery_id: claims[0].delivery_id,
    binding_id: "15200000-0000-4000-8000-000000000001",
    recipient_user_id: "15300000-0000-4000-8000-000000000001",
    kind: "message_created" as const,
  },
};
function request(body = "{}", auth = "Bearer " + secret) {
  return new Request("https://test.invalid/native-push-worker", {
    method: "POST",
    headers: { Authorization: auth },
    body,
  });
}
function fixture(options: {
  prepareNull?: boolean;
  remaining?: number;
  finish?: boolean;
  fail?: string;
  providerFails?: boolean;
} = {}) {
  const calls: { name: string; args: Record<string, unknown> }[] = [];
  const sent: NativePreparedPush[] = [];
  const database = {
    rpc: (name: string, args: Record<string, unknown>) => {
      calls.push({ name, args });
      let data: unknown;
      if (name === "native_push_claim") data = claims;
      else if (name === "native_push_prepare") {
        data = options.prepareNull ? null : {
          ...prepared,
          payload: { ...prepared.payload, delivery_id: args.p_delivery },
          lease_remaining_ms: options.remaining ?? 30000,
        };
      } else if (name === "native_push_finish") data = options.finish ?? true;
      else throw new Error("unexpected RPC");
      return Promise.resolve({
        data,
        error: name === options.fail
          ? { message: "private database detail" }
          : null,
      });
    },
  } as unknown as PushDatabase;
  const transport = {
    deliver: (item: NativePreparedPush, deadline?: number) => {
      sent.push(item);
      assert.ok(deadline! <= performance.now() + 30000);
      if (options.providerFails) {
        return Promise.reject(new Error("private provider detail"));
      }
      return Promise.resolve({
        outcome: "sent" as const,
        code: 200,
        retrySeconds: 30,
      });
    },
  };
  return { calls, sent, database, transport };
}
Deno.test("worker rejects method, credentials and disabled transport before database access", async () => {
  const f = fixture();
  for (
    const [req, transport, key, status] of [
      [new Request("https://test.invalid"), f.transport, secret, 405],
      [request("{}", "Bearer incorrect"), f.transport, secret, 401],
      [request(), f.transport, "short", 401],
      [request(), null, secret, 503],
    ] as const
  ) {
    assert.equal(
      (await handleNativePushWorker(req, f.database, transport, key)).status,
      status,
    );
  }
  assert.equal(f.calls.length, 0);
});
Deno.test("worker rejects arbitrary arguments, malformed and oversized bodies", async () => {
  const f = fixture();
  for (
    const [body, status] of [["{", 400], ['{"limit":999}', 400], [
      "x".repeat(32769),
      413,
    ]] as const
  ) {
    assert.equal(
      (await handleNativePushWorker(
        request(body),
        f.database,
        f.transport,
        secret,
      )).status,
      status,
    );
  }
  assert.equal(f.calls.length, 0);
});
Deno.test("worker sends only prepared capabilities and finishes each original lease", async () => {
  const f = fixture();
  const response = await handleNativePushWorker(
    request(),
    f.database,
    f.transport,
    secret,
  );
  assert.equal(response.status, 200);
  assert.deepEqual(await response.json(), {
    claimed: 2,
    sent: 2,
    invalid: 0,
    retry: 0,
    failed: 0,
    cancelled: 0,
  });
  assert.deepEqual(f.calls[0], {
    name: "native_push_claim",
    args: { p_limit: 4 },
  });
  assert.equal(f.sent.length, 2);
  for (const claim of claims) {
    const completed = f.calls.find((call) =>
      call.name === "native_push_finish" &&
      call.args.p_delivery === claim.delivery_id
    )!;
    assert.equal(completed.args.p_lease, claim.lease_token);
    assert.equal(completed.args.p_outcome, "sent");
  }
});
Deno.test("revoked prepare and expired leases never reach provider", async () => {
  for (
    const options of [{ prepareNull: true }, { remaining: 0 }, {
      remaining: 30001,
    }]
  ) {
    const f = fixture(options);
    const response = await handleNativePushWorker(
      request(),
      f.database,
      f.transport,
      secret,
    );
    assert.equal(response.status, 200);
    assert.equal(f.sent.length, 0);
    assert.ok(!f.calls.some((call) => call.name === "native_push_finish"));
    const counts = await response.json();
    assert.equal(counts.sent, 0);
    assert.equal(options.prepareNull ? counts.cancelled : counts.failed, 2);
  }
});
Deno.test("rejected completion fence is counted as cancellation rather than delivery", async () => {
  const f = fixture({ finish: false });
  const response = await handleNativePushWorker(
    request(),
    f.database,
    f.transport,
    secret,
  );
  const counts = await response.json();
  assert.equal(counts.sent, 0);
  assert.equal(counts.cancelled, 2);
});
Deno.test("worker failures retain recoverable leases and reveal no provider/database details", async () => {
  for (
    const fail of [
      "native_push_claim",
      "native_push_prepare",
      "native_push_finish",
      undefined,
    ]
  ) {
    const f = fixture({ fail, providerFails: fail === undefined });
    const response = await handleNativePushWorker(
      request(),
      f.database,
      f.transport,
      secret,
    );
    assert.equal(response.status, fail === "native_push_claim" ? 503 : 200);
    const text = await response.text();
    assert.ok(!text.includes("private"));
    if (fail !== "native_push_finish") {
      assert.ok(!f.calls.some((call) => call.name === "native_push_finish"));
    }
  }
});
