import { assertEquals, assertFalse } from "jsr:@std/assert@1.0.19";
import { handlePublicPreview } from "./handler.ts";
const id = "10000000-0000-4000-8000-000000000001";
const record = {
  id,
  name: "A public member",
  occupation: "Designer",
  summary: "Public biography",
  skills: ["Design"],
  searching_skills: ["Marketing"],
  contact_count: 2,
  avatar_path: id + "/avatar.png",
  auth_user_id: "SECRET",
  email: "SECRET",
  phone: "SECRET",
  roles: ["SECRET"],
  connections: ["SECRET"],
};
function setup(
  data: unknown = {
    profiles: [record],
    query: "",
    kind: "all",
    next_cursor: null,
  },
) {
  const calls: { name: string; args: Record<string, unknown> }[] = [];
  let allowed = true;
  const database = {
    rpc(name: string, args: Record<string, unknown>) {
      calls.push({ name, args });
      return Promise.resolve({
        data: name === "invite_request_limit" ? allowed : data,
        error: null,
      });
    },
  };
  const signer = (paths: string[]) =>
    Promise.resolve(
      new Map(paths.map((p) => [p, "https://storage.invalid/signed-avatar"])),
    );
  return {
    calls,
    database,
    signer,
    deny() {
      allowed = false;
    },
  };
}
const request = (body: unknown) =>
  new Request("https://preview.invalid", {
    method: "POST",
    body: JSON.stringify(body),
  });
Deno.test("anonymous preview returns only approved profile fields and signed avatars", async () => {
  const s = setup();
  const r = await handlePublicPreview(
    request({ action: "profiles" }),
    s.database,
    s.signer,
  );
  assertEquals(r.status, 200);
  const d = await r.json();
  const p = d.profiles[0];
  assertEquals(p.avatar_url, "https://storage.invalid/signed-avatar");
  for (
    const k of [
      "auth_user_id",
      "email",
      "phone",
      "roles",
      "connections",
      "avatar_path",
    ]
  ) assertFalse(k in p);
  assertEquals(s.calls.map((c) => c.name), [
    "invite_request_limit",
    "invite_request_limit",
    "public_preview",
  ]);
  assertEquals(r.headers.get("Cache-Control"), "no-store");
});
Deno.test("private actions and extra identity/cursor fields are rejected before database work", async () => {
  for (
    const body of [
      { action: "create" },
      { action: "history" },
      { action: "profiles", user_id: id },
      { action: "profile", profile_id: "bad" },
      { action: "get", request_id: id, actor: id },
      { action: "feed", cursor: [] },
      { action: "profiles", query: "x".repeat(201) },
    ]
  ) {
    const s = setup();
    assertEquals(
      (await handlePublicPreview(request(body), s.database, s.signer)).status,
      400,
    );
    assertEquals(s.calls.length, 0);
  }
});
Deno.test("rate-limited callers cannot trigger reads or signing", async () => {
  const s = setup();
  s.deny();
  let signed = false;
  assertEquals(
    (await handlePublicPreview(
      request({ action: "profiles" }),
      s.database,
      async () => {
        signed = true;
        return new Map();
      },
    )).status,
    429,
  );
  assertEquals(s.calls.length, 1);
  assertFalse(signed);
});
Deno.test("oversized streamed and malformed JSON bodies are rejected", async () => {
  const s = setup();
  const huge = new Request("https://preview.invalid", {
    method: "POST",
    body: "x".repeat(4097),
  });
  assertEquals(
    (await handlePublicPreview(huge, s.database, s.signer)).status,
    413,
  );
  const malformed = new Request("https://preview.invalid", {
    method: "POST",
    body: "{",
  });
  assertEquals(
    (await handlePublicPreview(malformed, s.database, s.signer)).status,
    400,
  );
  assertEquals(s.calls.length, 0);
});
Deno.test("closed or missing content remains unavailable and infrastructure failures are retryable", async () => {
  const s = setup({ request: null });
  assertEquals(
    await (await handlePublicPreview(
      request({ action: "get", request_id: id }),
      s.database,
      s.signer,
    )).json(),
    { request: null },
  );
  const p = setup();
  assertEquals(
    (await handlePublicPreview(
      request({ action: "profiles" }),
      p.database,
      () => Promise.reject(Error("storage down")),
    )).status,
    503,
  );
});
