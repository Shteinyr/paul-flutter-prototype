import { strict as assert } from "node:assert";
import { FcmTransport, type NativePreparedPush } from "./transport.ts";
const pair = await crypto.subtle.generateKey(
  {
    name: "RSASSA-PKCS1-v1_5",
    modulusLength: 2048,
    publicExponent: new Uint8Array([1, 0, 1]),
    hash: "SHA-256",
  },
  true,
  ["sign", "verify"],
);
const bytes = new Uint8Array(
  await crypto.subtle.exportKey("pkcs8", pair.privateKey),
);
const pem = "-----BEGIN PRIVATE KEY-----\n" +
  btoa(String.fromCharCode(...bytes)) + "\n-----END PRIVATE KEY-----";
const config = {
  projectId: "paul-test-project",
  clientEmail: "test@paul-test-project.iam.gserviceaccount.com",
  privateKey: pem,
};
const now = 1700000000000;
const item: NativePreparedPush = {
  token: "device-token-12345678901234567890",
  platform: "ios",
  payload: {
    version: 1,
    delivery_id: "15000000-0000-4000-8000-000000000001",
    binding_id: "15000000-0000-4000-8000-000000000002",
    recipient_user_id: "15000000-0000-4000-8000-000000000003",
    kind: "message_created",
  },
};
const decoded = (value: string) =>
  Uint8Array.from(
    atob(value.replaceAll("-", "+").replaceAll("_", "/")),
    (c) => c.charCodeAt(0),
  );
function provider(status = 200, code?: string, retry?: string) {
  type Sent = {
    message: {
      fid: string;
      token?: string;
      notification: { title: string; body: string };
      data: Record<string, string>;
      android: { notification: { tag: string } };
      apns: { headers: Record<string, string> };
    };
  };
  const state = { auth: 0, messages: [] as Sent[], jwt: "" };
  const send: typeof fetch = (input, init) => {
    const url = String(input);
    if (url === "https://oauth2.googleapis.com/token") {
      state.auth++;
      const form = new URLSearchParams(String(init?.body));
      state.jwt = form.get("assertion")!;
      assert.equal(
        form.get("grant_type"),
        "urn:ietf:params:oauth:grant-type:jwt-bearer",
      );
      return Promise.resolve(Response.json({
        access_token: "test-server-capability",
        expires_in: 3600,
      }));
    }
    assert.equal(
      url,
      "https://fcm.googleapis.com/v1/projects/paul-test-project/messages:send",
    );
    assert.equal(
      new Headers(init?.headers).get("Authorization"),
      "Bearer test-server-capability",
    );
    assert.equal(init?.redirect, "error");
    state.messages.push(JSON.parse(String(init?.body)));
    return Promise.resolve(Response.json(
      code
        ? {
          error: {
            details: [{
              "@type": "type.googleapis.com/google.firebase.fcm.v1.FcmError",
              errorCode: code,
            }],
          },
        }
        : { name: "accepted" },
      { status, headers: retry ? { "Retry-After": retry } : {} },
    ));
  };
  return { state, send };
}
Deno.test("FCM OAuth JWT is signed for messaging scope and concurrent sends share one access token", async () => {
  const f = provider();
  const transport = new FcmTransport(config, f.send, () => now);
  const results = await Promise.all([
    transport.deliver(item),
    transport.deliver(item),
  ]);
  assert.ok(results.every((result) => result.outcome === "sent"));
  assert.equal(f.state.auth, 1);
  const parts = f.state.jwt.split(".");
  assert.equal(parts.length, 3);
  const claims = JSON.parse(new TextDecoder().decode(decoded(parts[1])));
  assert.equal(claims.iss, config.clientEmail);
  assert.equal(
    claims.scope,
    "https://www.googleapis.com/auth/firebase.messaging",
  );
  assert.equal(claims.exp - claims.iat, 3600);
  assert.ok(
    await crypto.subtle.verify(
      "RSASSA-PKCS1-v1_5",
      pair.publicKey,
      decoded(parts[2]),
      new TextEncoder().encode(parts[0] + "." + parts[1]),
    ),
  );
});
for (
  const [kind, body] of [["message_created", "New message"], [
    "community_created",
    "New Hiring request",
  ]] as const
) {
  Deno.test(
    "provider notification is fixed and content-free: " + kind,
    async () => {
      const f = provider();
      const transport = new FcmTransport(config, f.send, () => now);
      await transport.deliver({
        ...item,
        payload: {
          ...item.payload,
          kind,
          text: "private text",
          name: "Private name",
        } as NativePreparedPush["payload"],
      });
      const message = f.state.messages[0].message;
      assert.equal(message.fid, item.token);
      assert.equal(message.token, undefined);
      assert.deepEqual(message.notification, { title: "Paul", body });
      assert.deepEqual(Object.keys(message.data).sort(), [
        "binding_id",
        "delivery_id",
        "kind",
        "recipient_user_id",
        "version",
      ]);
      assert.equal(
        message.apns.headers["apns-collapse-id"],
        item.payload.delivery_id,
      );
      assert.equal(message.android.notification.tag, item.payload.delivery_id);
      assert.ok(!JSON.stringify(message).includes("private text"));
    },
  );
}
for (
  const [status, code, outcome] of [
    [404, "UNREGISTERED", "invalid"],
    [400, "INVALID_ARGUMENT", "failed"],
    [403, "SENDER_ID_MISMATCH", "failed"],
    [429, "QUOTA_EXCEEDED", "retry"],
    [503, "UNAVAILABLE", "retry"],
  ] as const
) {
  Deno.test(`provider ${status}/${code} maps to ${outcome} without invalidating good tokens`, async () => {
    const f = provider(status, code, "120");
    const result = await new FcmTransport(config, f.send, () => now).deliver(
      item,
    );
    assert.equal(result.outcome, outcome);
    if (status === 429 || status === 503) {
      assert.equal(result.retrySeconds, 120);
    }
  });
}
Deno.test("expired lease skips OAuth and FCM calls", async () => {
  const f = provider();
  const result = await new FcmTransport(config, f.send, () => now).deliver(
    item,
    performance.now() + 100,
  );
  assert.equal(result.outcome, "retry");
  assert.equal(f.state.auth, 0);
  assert.equal(f.state.messages.length, 0);
});
Deno.test("an unknown provider outcome is retried with the original delivery identity", async () => {
  const f = provider();
  const send: typeof fetch = async (input, init) => {
    if (String(input).startsWith("https://fcm.googleapis.com/")) {
      throw new Error("lost acknowledgement");
    }
    return await f.send(input, init);
  };
  const result = await new FcmTransport(config, send, () => now).deliver(item);
  assert.equal(result.outcome, "retry");
});
