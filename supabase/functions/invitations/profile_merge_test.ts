import { assertEquals } from "jsr:@std/assert@1";

Deno.test("legacy writes require refresh; merge and registration forward verified actor and session", async () => {
  const actor = "13300000-0000-4000-8000-000000000001";
  const calls: { rpc: string; args: Record<string, unknown> }[] = [];
  const originalServe = Deno.serve;
  let rpcProblem: string | undefined;
  let admissionProblem: string | undefined;
  let registrationProblem: string | undefined;
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
    if (
      (rpc === "member_require_session" && admissionProblem) ||
      (["prepare_registration_session", "redeem_session_invitation"].includes(
        rpc,
      ) && registrationProblem)
    ) {
      return new Response(
        JSON.stringify({
          message: rpc === "member_require_session"
            ? admissionProblem
            : registrationProblem,
          code: "P0001",
        }),
        { status: 400, headers: { "Content-Type": "application/json" } },
      );
    }
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
      calls.find((c) => c.rpc === "redeem_session_invitation")?.args
        .p_profile,
      base,
    );
    const redemption = calls.find((c) =>
      c.rpc === "redeem_session_invitation"
    )!.args;
    assertEquals(redemption.p_user, actor);
    assertEquals(redemption.p_session, "13300000-0000-4000-8000-000000000002");
    assertEquals(
      calls.some((c) => c.rpc === "redeem_registration_invitation"),
      false,
    );
    result = await send({
      action: "prepare",
      credential: "b".repeat(64),
      p_user: "spoofed",
      p_session: "spoofed",
    });
    assertEquals(result.status, 200);
    await result.body?.cancel();
    const prepared = calls.find((c) =>
      c.rpc === "prepare_registration_session"
    )!.args;
    assertEquals(prepared.p_user, actor);
    assertEquals(prepared.p_session, "13300000-0000-4000-8000-000000000002");
    // During Edge-first rollout these RPCs are not installed yet. They must
    // fail closed rather than fall back to the unbound legacy redemption.
    registrationProblem = "new admission RPC not installed";
    for (const action of ["prepare", "redeem"]) {
      result = await send({
        action,
        credential: "c".repeat(64),
        profile: base,
      });
      assertEquals(result.status, 503);
      assertEquals(await result.json(), { code: "server_unavailable" });
    }
    assertEquals(
      calls.some((c) => c.rpc === "redeem_registration_invitation"),
      false,
    );
    registrationProblem = undefined;
    admissionProblem = "invitation_required";
    const priorNetworkCalls =
      calls.filter((c) => c.rpc === "member_network").length;
    const priorIssueCalls =
      calls.filter((c) => c.rpc === "issue_invitation").length;
    for (
      const body of [{ action: "network" }, {
        action: "issue",
        token: "d".repeat(64),
      }]
    ) {
      result = await send(body);
      assertEquals(result.status, 403);
      assertEquals(await result.json(), { code: "invitation_required" });
    }
    assertEquals(
      calls.filter((c) => c.rpc === "member_network").length,
      priorNetworkCalls,
    );
    assertEquals(
      calls.filter((c) => c.rpc === "issue_invitation").length,
      priorIssueCalls,
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
