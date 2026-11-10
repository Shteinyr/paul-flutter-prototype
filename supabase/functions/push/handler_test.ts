import { assert, assertEquals } from "jsr:@std/assert@1.0.19";
import { createClient } from "npm:@supabase/supabase-js@2.108.2";
import webpush from "npm:web-push@3.6.7";
import { createECDH, randomBytes } from "node:crypto";
import { Buffer } from "node:buffer";
import ece from "npm:http_ece@1.2.0";
import { handlePush } from "./handler.ts";
import { type PushConfig, validEndpoint } from "./shared.ts";
import { deliverPush, type PreparedPush } from "./transport.ts";
import { handlePushWorker } from "../push-worker/handler.ts";

const actor = "78000000-0000-4000-8000-000000000001";
const session = "78100000-0000-4000-8000-000000000001";
const binding = "78200000-0000-4000-8000-000000000001";
const delivery = "78300000-0000-4000-8000-000000000001";
const token = "e30." +
  btoa(JSON.stringify({ sub: actor, session_id: session })).replaceAll(
    "=",
    "",
  ) + ".signature";
const vapid = webpush.generateVAPIDKeys();
const config: PushConfig = {
  enabled: true,
  publicKey: vapid.publicKey,
  privateKey: vapid.privateKey,
  subject: "https://paul.example.test",
  allowedOrigins: ["https://paul.example.test"],
};
const recipientKey = createECDH("prime256v1");
recipientKey.generateKeys();
const auth = randomBytes(16);
const subscription = {
  endpoint: "https://fcm.googleapis.com/fcm/send/unit-push-capability",
  expirationTime: null,
  keys: {
    p256dh: recipientKey.getPublicKey().toString("base64url"),
    auth: auth.toString("base64url"),
  },
};
const prepared: PreparedPush = {
  endpoint: subscription.endpoint,
  keys: subscription.keys,
  payload: {
    version: 1,
    delivery_id: delivery,
    binding_id: binding,
    recipient_user_id: actor,
  },
};

function database(result: unknown = {}, error?: string) {
  const calls: { name: string; body: Record<string, unknown> }[] = [];
  const client = createClient(
    "https://push-unit.invalid",
    "unit-publishable-key",
    {
      auth: { persistSession: false, autoRefreshToken: false },
      global: {
        fetch: (input, init) => {
          const path = new URL(String(input)).pathname;
          if (path === "/auth/v1/user") {
            return Promise.resolve(
              Response.json({ id: actor, is_anonymous: false }),
            );
          }
          calls.push({
            name: path.split("/").pop()!,
            body: JSON.parse(String(init?.body)),
          });
          return Promise.resolve(
            error
              ? Response.json({ code: "P0001", message: error }, {
                status: 400,
              })
              : Response.json(result),
          );
        },
      },
    },
  );
  return { client, calls };
}
function request(body: unknown, bearer = token) {
  return new Request("https://push-unit.invalid/functions/v1/push", {
    method: "POST",
    headers: {
      Authorization: "Bearer " + bearer,
      Origin: config.allowedOrigins[0],
    },
    body: JSON.stringify(body),
  });
}

Deno.test("config discovery is public and exposes only the public VAPID key", async () => {
  const db = database();
  const response = await handlePush(
    request({ action: "config" }, ""),
    db.client,
    config,
  );
  assertEquals(await response.json(), {
    version: 1,
    enabled: true,
    vapid_public_key: config.publicKey,
  });
  assertEquals(db.calls.length, 0);
  const disabled = await handlePush(request({ action: "config" }), db.client, {
    ...config,
    enabled: false,
  });
  assertEquals(await disabled.json(), {
    version: 1,
    enabled: false,
    vapid_public_key: null,
  });
});

Deno.test("subscribe pins the verified actor and JWT session and validates browser keys", async () => {
  const db = database({
    binding_id: binding,
    recipient_user_id: actor,
    enabled: true,
  });
  const response = await handlePush(
    request({ action: "subscribe", binding_id: binding, subscription }),
    db.client,
    config,
  );
  assertEquals(response.status, 200);
  assertEquals(db.calls, [{
    name: "push_subscribe",
    body: {
      p_user: actor,
      p_session: session,
      p_binding: binding,
      p_endpoint: subscription.endpoint,
      p_p256dh: subscription.keys.p256dh,
      p_auth: subscription.keys.auth,
      p_expires: null,
    },
  }]);
  const forged = await handlePush(
    request({
      action: "subscribe",
      binding_id: binding,
      subscription,
      p_user: actor,
    }),
    db.client,
    config,
  );
  assertEquals(forged.status, 400);
  const invalid = await handlePush(
    request({
      action: "subscribe",
      binding_id: binding,
      subscription: {
        ...subscription,
        keys: { p256dh: "A".repeat(87), auth: "B".repeat(22) },
      },
    }),
    db.client,
    config,
  );
  assertEquals(invalid.status, 400);
  assertEquals(db.calls.length, 1);
});

Deno.test("private actions require a verified session claim and exact DTO fields", async () => {
  const db = database();
  for (
    const body of [
      {
        action: "status",
        binding_id: binding,
        endpoint: subscription.endpoint,
      },
      { action: "resolve", binding_id: binding, event_id: delivery },
      { action: "resolve", binding_id: binding, delivery_id: "bad" },
      { action: "unsubscribe", binding_id: "bad" },
    ]
  ) {
    assertEquals(
      (await handlePush(request(body), db.client, config)).status,
      400,
    );
  }
  const noSession = "e30." + btoa(JSON.stringify({ sub: actor })) +
    ".signature";
  assertEquals(
    (await handlePush(
      request({ action: "status", binding_id: binding }, noSession),
      db.client,
      config,
    )).status,
    401,
  );
  assertEquals(db.calls.length, 0);
});

Deno.test("current database denials remain explicit across status detach and resolve", async () => {
  for (
    const [code, status] of [
      ["session_revoked", 401],
      ["membership_required", 403],
      ["push_forbidden", 403],
      ["binding_conflict", 409],
      ["rate_limited", 429],
      ["unknown internal error", 503],
    ] as const
  ) {
    const db = database(null, code);
    const response = await handlePush(
      request({
        action: "resolve",
        delivery_id: delivery,
        binding_id: binding,
      }),
      db.client,
      config,
    );
    assertEquals(response.status, status);
    assertEquals(db.calls[0].body, {
      p_user: actor,
      p_session: session,
      p_binding: binding,
      p_delivery: delivery,
    });
    assert(!JSON.stringify(await response.json()).includes("internal"));
  }
});

Deno.test("request bounds reject chunked overflow and CORS rejects another origin", async () => {
  const db = database();
  const oversized = new Request("https://push-unit.invalid", {
    method: "POST",
    body: new ReadableStream({
      start(controller) {
        controller.enqueue(new Uint8Array(8193));
        controller.close();
      },
    }),
  });
  assertEquals((await handlePush(oversized, db.client, config)).status, 413);
  const foreign = new Request("https://push-unit.invalid", {
    method: "POST",
    headers: { Origin: "https://other.invalid" },
    body: '{"action":"config"}',
  });
  assertEquals((await handlePush(foreign, db.client, config)).status, 403);
  const preflight = new Request("https://push-unit.invalid", {
    method: "OPTIONS",
    headers: { Origin: config.allowedOrigins[0] },
  });
  const response = await handlePush(preflight, db.client, config);
  assertEquals(response.status, 204);
  assertEquals(
    response.headers.get("Access-Control-Allow-Origin"),
    config.allowedOrigins[0],
  );
  assertEquals(db.calls.length, 0);
});

Deno.test("provider endpoint validation closes SSRF credentials normalization and query bypasses", () => {
  for (
    const endpoint of [
      "http://fcm.googleapis.com/fcm/send/id",
      "https://127.0.0.1/fcm/send/id",
      "https://[::1]/wp/id",
      "https://fcm.googleapis.com.evil.test/fcm/send/id",
      "https://fcm.googleapis.com@evil.test/wp/id",
      "https://fcm.googleapis.com:444/fcm/send/id",
      "https://fcm.googleapis.com/fcm/send/id?next=http://localhost",
      "https://fcm.googleapis.com/fcm/send/id#x",
      "https://FCM.GOOGLEAPIS.COM/fcm/send/id",
      "https://fcm.googleapis.com/../../wp/id",
      "https://metadata.google.internal/wp/id",
      "https://evil.test/wp/id",
    ]
  ) assertEquals(validEndpoint(endpoint), false, endpoint);
  assertEquals(validEndpoint(subscription.endpoint), true);
  assertEquals(
    validEndpoint("https://updates.push.services.mozilla.com/wpush/v2/unit"),
    true,
  );
  assertEquals(validEndpoint("https://web.push.apple.com/unit"), true);
});

Deno.test("standard VAPID transport encrypts only the minimal payload and never follows redirects", async () => {
  let calls = 0;
  const result = await deliverPush(prepared, config, async (input, options) => {
    calls++;
    assertEquals(input, subscription.endpoint);
    assertEquals(options?.redirect, "error");
    assert(options?.signal);
    const headers = new Headers(options?.headers);
    assertEquals(headers.get("Content-Encoding"), "aes128gcm");
    assertEquals(headers.get("TTL"), "300");
    assertEquals(headers.get("Topic"), delivery.replaceAll("-", ""));
    assert(headers.get("Authorization")?.startsWith("vapid "));
    const body = options?.body as Uint8Array;
    const decoded = ece.decrypt(Buffer.from(body), {
      version: "aes128gcm",
      privateKey: recipientKey,
      authSecret: auth,
    });
    assertEquals(JSON.parse(decoded.toString()), prepared.payload);
    assert(!new TextDecoder().decode(body).includes(binding));
    return new Response(null, { status: 201 });
  });
  assertEquals(calls, 1);
  assertEquals(result.outcome, "sent");
});

Deno.test("delivery outcomes bound retries and discard invalid subscriptions without response leakage", async () => {
  for (
    const [status, expected] of [
      [201, "sent"],
      [404, "invalid"],
      [410, "invalid"],
      [301, "failed"],
      [403, "failed"],
      [429, "retry"],
      [500, "retry"],
    ] as const
  ) {
    const result = await deliverPush(
      prepared,
      config,
      () =>
        Promise.resolve(
          new Response("private endpoint failure", {
            status,
            headers: { "Retry-After": "999999" },
          }),
        ),
    );
    assertEquals(result.outcome, expected);
    assert(result.retrySeconds <= 3600);
    assert(!JSON.stringify(result).includes("private endpoint"));
  }
  const failed = await deliverPush(
    prepared,
    config,
    () => Promise.reject(new Error("network unknown commit")),
  );
  assertEquals(failed.outcome, "retry");
  let called = false;
  const noLease = await deliverPush(prepared, config, () => {
    called = true;
    throw new Error();
  }, performance.now());
  assertEquals(noLease.outcome, "retry");
  assertEquals(called, false);
});

Deno.test("worker requires its private secret before any database call", async () => {
  const db = database();
  const response = await handlePushWorker(
    request({}),
    db.client,
    config,
    "private-worker-secret-".repeat(3),
  );
  assertEquals(response.status, 401);
  assertEquals(db.calls.length, 0);
});

Deno.test("worker bounds concurrency and fences each successful HTTP outcome", async () => {
  const calls: { name: string; args: Record<string, unknown> }[] = [];
  const claims = Array.from(
    { length: 4 },
    () => ({
      delivery_id: crypto.randomUUID(),
      lease_token: crypto.randomUUID(),
    }),
  );
  const client = createClient("https://push-unit.invalid", "unit-publishable", {
    auth: { persistSession: false },
    global: {
      fetch: (input, init) => {
        const name = new URL(String(input)).pathname.split("/").pop()!;
        const args = JSON.parse(String(init?.body));
        calls.push({ name, args });
        const result = name === "push_claim"
          ? claims
          : name === "push_prepare"
          ? {
            ...prepared,
            lease_remaining_ms: 30000,
            payload: { ...prepared.payload, delivery_id: args.p_delivery },
          }
          : true;
        return Promise.resolve(Response.json(result));
      },
    },
  });
  let running = 0;
  let maximum = 0;
  const secret = "private-worker-secret-".repeat(3);
  const response = await handlePushWorker(
    request({}, secret),
    client,
    config,
    secret,
    async () => {
      running++;
      maximum = Math.max(running, maximum);
      await new Promise((resolve) => setTimeout(resolve, 5));
      running--;
      return new Response(null, { status: 201 });
    },
  );
  assertEquals(await response.json(), {
    claimed: 4,
    sent: 4,
    invalid: 0,
    retry: 0,
    failed: 0,
    cancelled: 0,
  });
  assertEquals(maximum, 2);
  assertEquals(calls[0], { name: "push_claim", args: { p_limit: 4 } });
  for (const claim of claims) {
    assert(
      calls.some((call) =>
        call.name === "push_prepare" &&
        call.args.p_delivery === claim.delivery_id &&
        call.args.p_lease === claim.lease_token
      ),
    );
    assert(
      calls.some((call) =>
        call.name === "push_finish" &&
        call.args.p_delivery === claim.delivery_id &&
        call.args.p_lease === claim.lease_token &&
        call.args.p_outcome === "sent"
      ),
    );
  }
});

Deno.test("worker never sends after an insufficient preflight lease budget", async () => {
  const calls: string[] = [];
  const client = createClient("https://push-unit.invalid", "unit-publishable", {
    auth: { persistSession: false },
    global: {
      fetch: (input) => {
        const name = new URL(String(input)).pathname.split("/").pop()!;
        calls.push(name);
        return Promise.resolve(Response.json(
          name === "push_claim"
            ? [{ delivery_id: delivery, lease_token: binding }]
            : name === "push_prepare"
            ? { ...prepared, lease_remaining_ms: 5000 }
            : true,
        ));
      },
    },
  });
  let network = 0;
  const secret = "private-worker-secret-".repeat(3);
  const response = await handlePushWorker(
    request({}, secret),
    client,
    config,
    secret,
    () => {
      network++;
      return Promise.resolve(new Response(null, { status: 201 }));
    },
  );
  assertEquals(network, 0);
  assertEquals((await response.json()).retry, 1);
  assertEquals(calls, ["push_claim", "push_prepare", "push_finish"]);
});

Deno.test("invalid endpoint is revalidated directly before delivery", async () => {
  let network = 0;
  const result = await deliverPush(
    { ...prepared, endpoint: "https://127.0.0.1/private" },
    config,
    () => {
      network++;
      throw new Error();
    },
  );
  assertEquals(result.outcome, "failed");
  assertEquals(network, 0);
});

Deno.test("worker rechecks claims before sending and a revoke produces no HTTP request", async () => {
  const calls: string[] = [];
  const client = createClient("https://push-unit.invalid", "unit-publishable", {
    auth: { persistSession: false },
    global: {
      fetch: (input) => {
        const name = new URL(String(input)).pathname.split("/").pop()!;
        calls.push(name);
        return Promise.resolve(Response.json(
          name === "push_claim"
            ? [{ delivery_id: delivery, lease_token: binding }]
            : null,
        ));
      },
    },
  });
  const secret = "private-worker-secret-".repeat(3);
  const response = await handlePushWorker(
    request({}, secret),
    client,
    config,
    secret,
    () => {
      throw new Error("HTTP must not be called after revoke");
    },
  );
  assertEquals(response.status, 200);
  assertEquals((await response.json()).cancelled, 1);
  assertEquals(calls, ["push_claim", "push_prepare"]);
});
