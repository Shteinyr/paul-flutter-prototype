import { createClient } from "npm:@supabase/supabase-js@2.108.2";
import { handleAdmin } from "./handler.ts";

const actor = "42000000-0000-4000-8000-000000000001";
function check(value: boolean, description: string) {
  if (!value) throw new Error(description);
}
function setup(denied = false, anonymous = false) {
  const calls: { url: string; body: unknown }[] = [];
  const database = createClient("https://admin-test.invalid", "test-key", {
    auth: { persistSession: false, autoRefreshToken: false },
    global: {
      fetch: (input, options) => {
        const url = String(input);
        calls.push({
          url,
          body: options?.body ? JSON.parse(String(options.body)) : null,
        });
        const isPrivileged = [
          "/admin_context",
          "/admin_prepare_create",
          "/admin_authorize_save",
          "/admin_save_profile",
        ].some((path) => url.endsWith(path));
        const body = url.endsWith("/auth/v1/user")
          ? {
            id: actor,
            is_anonymous: anonymous,
            user_metadata: { admin: true, role: "owner" },
          }
          : url.endsWith("/invite_request_limit")
          ? true
          : denied
          ? { message: "admin_forbidden", code: "P0001" }
          : url.endsWith("/admin_prepare_create")
          ? "43000000-0000-4000-8000-000000000010"
          : { role: "admin", profiles: [] };
        return Promise.resolve(
          new Response(JSON.stringify(body), {
            status: isPrivileged && denied ? 400 : 200,
            headers: { "Content-Type": "application/json" },
          }),
        );
      },
    },
  });
  return { database, calls };
}
function request(body: unknown, authorization = "Bearer test-session") {
  return new Request("https://admin-test.invalid", {
    method: "POST",
    headers: { Authorization: authorization },
    body: JSON.stringify(body),
  });
}
Deno.test("context actor comes exclusively from verified Auth", async () => {
  const { database, calls } = setup();
  const response = await handleAdmin(request({ action: "context" }), database);
  check(response.status === 200, "Admin context succeeds");
  const args = calls.find((call) => call.url.endsWith("/admin_context"))
    ?.body as Record<string, unknown>;
  check(args.p_actor === actor, "Uses verified Auth actor");
});
Deno.test("client cannot substitute actor or grant roles", async () => {
  for (
    const body of [{ action: "context", p_actor: actor }, {
      action: "context",
      role: "owner",
    }, { action: "grant", user_id: actor }]
  ) {
    const { database, calls } = setup();
    check(
      (await handleAdmin(request(body), database)).status === 400,
      "Reject unknown fields/actions",
    );
    check(
      calls.every((call) => !call.url.includes("/rpc/")),
      "No RPC on forged body",
    );
  }
});
Deno.test("editable metadata never bypasses a server role denial", async () => {
  const { database } = setup(true);
  check(
    (await handleAdmin(request({ action: "context" }), database)).status ===
      403,
    "Server grant denial wins",
  );
});
Deno.test("missing or anonymous Auth cannot access administration", async () => {
  const { database, calls } = setup(false, true);
  check(
    (await handleAdmin(request({ action: "context" }), database)).status ===
      401,
    "Anonymous is rejected",
  );
  check(calls.every((call) => !call.url.includes("/rpc/")), "No anonymous RPC");
  check(
    (await handleAdmin(request({ action: "context" }, ""), database)).status ===
      401,
    "Bearer required",
  );
});

Deno.test("create profile ID is allocated by the server and never chosen by the browser", async () => {
  const { database, calls } = setup();
  const response = await handleAdmin(
    request({
      action: "save",
      create: true,
      client_operation_id: actor,
      profile: {
        name: "Managed QA",
        occupation: "",
        summary: "Test",
        skills: ["Design"],
        searching_skills: [],
      },
    }),
    database,
  );
  check(response.status === 200, "Create succeeds");
  const args = calls.find((call) => call.url.endsWith("/admin_save_profile"))
    ?.body as Record<string, unknown>;
  check(
    args.p_profile === "43000000-0000-4000-8000-000000000010",
    "Only the reserved UUID reaches save",
  );
  const forged = await handleAdmin(
    request({
      action: "save",
      create: true,
      profile_id: actor,
      client_operation_id: actor,
      profile: {},
    }),
    database,
  );
  check(forged.status === 400, "Browser cannot reserve an Auth UUID");
});
Deno.test("photo upload requires a fresh server authorization", async () => {
  const { database, calls } = setup(true);
  const photo = new Uint8Array(24);
  photo.set([137, 80, 78, 71, 13, 10, 26, 10]);
  const response = await handleAdmin(
    request({
      action: "save",
      create: false,
      profile_id: actor,
      client_operation_id: actor,
      profile: {},
      photo_base64: btoa(String.fromCharCode(...photo)),
    }),
    database,
  );
  check(response.status === 403, "Role denial prevents upload");
  check(
    calls.every((call) => !call.url.includes("/storage/")),
    "No file upload before authorization",
  );
});
