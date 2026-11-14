import { assertEquals } from "jsr:@std/assert@1";

Deno.test("legacy writes require refresh; merge forwards a verified actor; registration is unchanged", async () => {
  const actor = "13300000-0000-4000-8000-000000000001";
  const calls: { rpc: string; args: Record<string, unknown> }[] = [];
  const originalServe = Deno.serve;
  let rpcProblem: string | undefined;
  const json = (value: unknown) =>
    new Response(JSON.stringify(value), {
      headers: { "Content-Type": "application/json" },
    });
  const backend = originalServe({
    hostname: "127.0.0.1",
    port: 0,
    onListen: () => {},
  }, async (request) => {
    const path = new URL(request.url).pathname;
    if (path.endsWith("/auth/v1/user")) {
      return json({
        id: actor,
        is_anonymous: false,
        identities: [],
        app_metadata: {},
      });
    }
    const rpc = path.split("/").at(-1)!;
    const args = await request.json();
    calls.push({ rpc, args });
    if (rpc === "merge_member_profile" && rpcProblem) {
      return new Response(
        JSON.stringify({ message: rpcProblem, code: "P0001" }),
        { status: 400, headers: { "Content-Type": "application/json" } },
      );
    }
    return json(
      rpc === "invite_request_limit"
        ? true
        : rpc === "member_require_auth_session"
        ? null
        : { profile: { id: actor } },
    );
  });
  const oldUrl = Deno.env.get("SUPABASE_URL"),
    oldKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  Deno.env.set("SUPABASE_URL", `http://127.0.0.1:${backend.addr.port}`);
  Deno.env.set("SUPABASE_SERVICE_ROLE_KEY", "local-test-only");
  let handler: (request: Request) => Promise<Response> = () =>
    Promise.reject(new Error("Handler not loaded"));
  // Capture the real handler without opening its deployment listener.
  Deno.serve = ((callback: typeof handler) => {
    handler = callback;
    return {} as Deno.HttpServer;
  }) as typeof Deno.serve;
  try {
    await import("./index.ts");
    Deno.serve = originalServe;
    const jwt = "e30." +
      btoa(
        JSON.stringify({
          sub: actor,
          session_id: "13300000-0000-4000-8000-000000000002",
        }),
      ) + ".signature";
    const send = (body: unknown) =>
      handler(
        new Request("http://local.invalid", {
          method: "POST",
          headers: { Authorization: `Bearer ${jwt}` },
          body: JSON.stringify(body),
        }),
      );
    const base = {
      name: "Name",
      occupation: "",
      summary: "Summary",
      skills: ["Design"],
      searching_skills: [],
      avatar_path: null,
    };
    let result = await send({ action: "save_profile", profile: base });
    assertEquals(result.status, 409);
    assertEquals(await result.json(), {
      code: "profile_upgrade_required",
      message: "Refresh this page to save your changes",
    });
    assertEquals(calls.some((c) => c.rpc === "save_member_profile"), false);
    result = await send({
      action: "merge_profile",
      operation_id: "13300000-0000-4000-8000-000000000003",
      base,
      changes: { name: "New name" },
      p_user: "spoofed",
    });
    assertEquals(result.status, 200);
    await result.body?.cancel();
    assertEquals(
      calls.find((c) => c.rpc === "merge_member_profile")?.args.p_user,
      actor,
    );
    result = await send({
      action: "merge_profile",
      operation_id: "13300000-0000-4000-8000-000000000003",
      base,
      changes: { auth_user_id: "spoofed" },
    });
    assertEquals(result.status, 400);
    await result.body?.cancel();
    rpcProblem = "profile_conflict";
    result = await send({
      action: "merge_profile",
      operation_id: "13300000-0000-4000-8000-000000000004",
      base,
      changes: { name: "Conflicting name" },
    });
    assertEquals(result.status, 409);
    assertEquals(await result.json(), { code: "profile_conflict" });
    rpcProblem = undefined;
    result = await send({
      action: "redeem",
      credential: "a".repeat(64),
      profile: base,
    });
    assertEquals(result.status, 200);
    await result.body?.cancel();
    assertEquals(
      calls.find((c) => c.rpc === "redeem_registration_invitation")?.args
        .p_profile,
      base,
    );
  } finally {
    Deno.serve = originalServe;
    if (oldUrl === undefined) Deno.env.delete("SUPABASE_URL");
    else Deno.env.set("SUPABASE_URL", oldUrl);
    if (oldKey === undefined) Deno.env.delete("SUPABASE_SERVICE_ROLE_KEY");
    else Deno.env.set("SUPABASE_SERVICE_ROLE_KEY", oldKey);
    await backend.shutdown();
  }
});
