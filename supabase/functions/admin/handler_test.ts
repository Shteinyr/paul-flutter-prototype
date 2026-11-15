import { createClient } from "npm:@supabase/supabase-js@2.108.2";
import { handleAdmin } from "./handler.ts";

const actor = "42000000-0000-4000-8000-000000000001";
function check(value: boolean, description: string) {
  if (!value) throw new Error(description);
}
function setup(denied = false, anonymous = false, admissionDenied = false) {
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
        if (url.endsWith("/member_require_session")) {
          return Promise.resolve(
            Response.json(
              admissionDenied
                ? { message: "invitation_required", code: "P0001" }
                : null,
              { status: admissionDenied ? 400 : 200 },
            ),
          );
        }
        const isPrivileged = url.includes("/rest/v1/rpc/") &&
          !url.endsWith("/invite_request_limit");
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
const testSession = "72100000-0000-4000-8000-000000000003";
const validBearer = "Bearer unit." +
  btoa(JSON.stringify({ session_id: testSession })) + ".signature";
function request(body: unknown, authorization = validBearer) {
  return new Request("https://admin-test.invalid", {
    method: "POST",
    headers: { Authorization: authorization },
    body: JSON.stringify(body),
  });
}
Deno.test("managed deletion requires confirmation and a verified session and preserves its retry command", async () => {
  const session = "72100000-0000-4000-8000-000000000003";
  const profile = "72200000-0000-4000-8000-000000000004";
  const version = "2026-11-11T00:00:00Z";
  const body = {
    action: "delete",
    profile_id: profile,
    client_operation_id: actor,
    confirm: true,
    expected_updated_at: version,
  };
  const authorization = "Bearer unit." +
    btoa(JSON.stringify({ session_id: session })) + ".signature";
  const { database, calls } = setup();
  for (
    const extra of [{ confirm: false }, { expected_updated_at: "invalid" }]
  ) {
    check(
      (await handleAdmin(
        request({ ...body, ...extra }, authorization),
        database,
      ))
        .status === 400,
      "Unconfirmed or malformed deletion is rejected",
    );
  }
  check(
    !calls.some((call) => call.url.endsWith("/admin_delete_profile")),
    "Invalid deletion never reaches the command",
  );
  check(
    (await handleAdmin(request(body, "Bearer test-session"), database))
      .status === 401,
    "Live session UUID is required",
  );
  for (let attempt = 0; attempt < 2; attempt++) {
    check(
      (await handleAdmin(request(body, authorization), database)).status ===
        200,
      "Original deletion request remains retryable",
    );
  }
  const deletions = calls.filter((call) =>
    call.url.endsWith("/admin_delete_profile")
  );
  check(
    deletions.length === 4,
    "Each request invokes command then status retry",
  );
  const expected = JSON.stringify({
    p_actor: actor,
    p_profile: profile,
    p_client_operation: actor,
    p_expected_updated_at: version,
    p_session: session,
  });
  check(
    deletions.every((call) => JSON.stringify(call.body) === expected),
    "Auth actor, target, operation, original version and session stay identical",
  );
  check(
    !calls.some((call) => call.url.includes("/auth/v1/admin/users/")),
    "Managed deletion never selects an Auth user for direct removal",
  );
});
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

Deno.test("operator send pins Auth actor and validates managed sender and raw text", async () => {
  const { database, calls } = setup();
  const text = "e\u0301".repeat(2000);
  const response = await handleAdmin(
    request({
      action: "send",
      profile_id: "45000000-0000-4000-8000-000000000001",
      conversation_id: actor,
      client_message_id: actor,
      text,
    }),
    database,
  );
  check(response.status === 200, "2000 graphemes allowed");
  const args = calls.find((call) => call.url.endsWith("/operator_send"))
    ?.body as Record<string, unknown>;
  check(
    args.p_actor === actor &&
      args.p_profile === "45000000-0000-4000-8000-000000000001" &&
      args.p_text === text,
    "Verified actor and exact text reach RPC",
  );
  for (
    const extra of [
      { sender_profile_id: "45000000-0000-4000-8000-000000000001" },
      { actor_user_id: actor },
      {
        p_actor: actor,
      },
    ]
  ) {
    const forged = await handleAdmin(
      request({
        action: "send",
        profile_id: "45000000-0000-4000-8000-000000000001",
        conversation_id: actor,
        client_message_id: actor,
        text: "Test",
        ...extra,
      }),
      database,
    );
    check(forged.status === 400, "Unapproved identity fields rejected");
  }
});
Deno.test("operator send denies oversized blank and NUL payloads", async () => {
  for (const text of [" \n", "bad\0text", "e\u0301".repeat(2001)]) {
    const { database, calls } = setup();
    const response = await handleAdmin(
      request({
        action: "send",
        profile_id: actor,
        conversation_id: actor,
        client_message_id: actor,
        text,
      }),
      database,
    );
    check(response.status === 400, "Invalid message rejected");
    check(
      calls.every((call) => !call.url.endsWith("/operator_send")),
      "No invalid send reaches SQL",
    );
  }
});
Deno.test("operator inbox history and read preserve server access denial", async () => {
  for (
    const fields of [{ action: "inbox" }, {
      action: "history",
      conversation_id: actor,
    }, { action: "read", conversation_id: actor, through_seq: 0 }]
  ) {
    const { database } = setup(true);
    const response = await handleAdmin(
      request({ profile_id: actor, ...fields }),
      database,
    );
    check(response.status === 403, "Server role denial preserved");
  }
});

Deno.test("unadmitted admin session cannot read or mutate managed profiles", async () => {
  const { database, calls } = setup(false, false, true);
  const response = await handleAdmin(request({ action: "context" }), database);
  check(
    response.status === 403,
    "Requires a fresh invitation for this session",
  );
  check(
    !calls.some((call) => call.url.endsWith("/admin_context")),
    "No administration before admission",
  );
});
