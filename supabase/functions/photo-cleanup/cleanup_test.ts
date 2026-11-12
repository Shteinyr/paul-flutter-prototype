import { createClient } from "npm:@supabase/supabase-js@2.108.2";
import { cleanupAvatars } from "./cleanup.ts";
import { handleAdmin } from "../admin/handler.ts";
const actor = "73000000-0000-4000-8000-000000000001";
const paths = [
  `${actor}/${"a".repeat(64)}.png`,
  `${actor}/${"b".repeat(64)}.png`,
];
function check(value: unknown, message: string) {
  if (!value) throw new Error(message);
}
function fixture(mode = "normal") {
  const files = new Set(paths),
    finished = new Set<string>(),
    leased = new Set<string>(),
    calls: { name: string; body: Record<string, unknown> }[] = [];
  let failures = mode === "partial failure" ? 1 : 0,
    ackFailures = mode === "lost finish" ? 1 : 0;
  const database = createClient("https://photo-test.invalid", "test-key", {
    auth: { persistSession: false, autoRefreshToken: false },
    global: {
      fetch: (input, init) => {
        const url = String(input), name = url.split("/").pop()!;
        let body: Record<string, unknown> = {};
        try {
          body = JSON.parse(String(init?.body));
        } catch {}
        calls.push({ name, body });
        const json = (value: unknown, status = 200) =>
          Response.json(value, { status });
        if (name === "avatar_cleanup_claim") {
          if (mode === "staged") {
            return Promise.resolve(
              json({ code: "PGRST202", message: "not installed" }, 404),
            );
          }
          if (mode === "malformed") {
            return Promise.resolve(
              json([{
                path: "../unknown.png",
                lease_token: crypto.randomUUID(),
              }]),
            );
          }
          return Promise.resolve(json(
            paths.filter((p) => !finished.has(p) && !leased.has(p)).map((p) => {
              leased.add(p);
              return { path: p, lease_token: crypto.randomUUID() };
            }),
          ));
        }
        if (name === "avatar_cleanup_prepare") {
          return Promise.resolve(json(
            mode === "stale"
              ? null
              : { path: body.p_path, exists: files.has(String(body.p_path)) },
          ));
        }
        if (name === "avatars") {
          check(init?.method === "DELETE", "Storage DELETE only");
          const names = body.prefixes as string[];
          check(
            names.length === 1 && paths.includes(names[0]),
            "Exactly the prepared immutable path",
          );
          if (failures-- > 0) {
            return Promise.resolve(
              json({ message: "unavailable", statusCode: "503" }, 503),
            );
          }
          for (const p of names) {
            files.delete(p);
          }
          return Promise.resolve(json(names.map((name) => ({ name }))));
        }
        if (name === "avatar_cleanup_finish") {
          if (ackFailures-- > 0) {
            return Promise.resolve(json({ message: "unavailable" }, 503));
          }
          const path = String(body.p_path);
          leased.delete(path);
          if (!files.has(path)) finished.add(path);
          return Promise.resolve(
            json({ state: finished.has(path) ? "deleted" : "deleting" }),
          );
        }
        throw Error("Unexpected local fixture call " + name);
      },
    },
  });
  return { database, files, calls, finished };
}
Deno.test("cleanup uses bounded single-path Storage deletes and idempotent completion", async () => {
  const f = fixture();
  try {
    const r = await cleanupAvatars(f.database);
    check(r.complete === 2 && f.files.size === 0, "Both removed");
    check(
      (await cleanupAvatars(f.database)).claimed === 0,
      "No replayed deletion",
    );
  } finally {
    await f.database.auth.stopAutoRefresh();
  }
});
Deno.test("partial Storage failure retries only the remaining object", async () => {
  const f = fixture("partial failure");
  const first = await cleanupAvatars(f.database);
  check(
    first.retry === 1 && first.complete === 1 && f.files.size === 1,
    "Partial commit retained",
  );
  const second = await cleanupAvatars(f.database);
  check(
    second.claimed === 1 && second.complete === 1 && f.files.size === 0,
    "Retry completed remaining object",
  );
});
Deno.test("unconfirmed finish is safe after Storage has already removed the file", async () => {
  const f = fixture("lost finish");
  const r = await cleanupAvatars(f.database);
  check(r.complete === 2, "Fallback acknowledgement confirms SQL state");
  check(
    f.calls.filter((c) => c.name === "avatars").length === 2,
    "No duplicate external mutation required",
  );
});
for (const mode of ["stale", "malformed", "staged"]) {
  Deno.test(`${mode} claims never mutate Storage`, async () => {
    const f = fixture(mode);
    const r = await cleanupAvatars(f.database);
    check(!f.calls.some((c) => c.name === "avatars"), "No delete");
    check(mode !== "staged" || r.pending, "Missing staged SQL reported");
  });
}
Deno.test("exhausted request budget leaves only durable retry work", async () => {
  const f = fixture();
  const r = await cleanupAvatars(f.database, 0);
  check(
    r.retry === 2 && !f.calls.some((c) => c.name === "avatars"),
    "No late DELETE",
  );
});

for (const replay of [false, true]) {
  Deno.test(`Admin photo allocation preserves operation id and skips upload on replay=${replay}`, async () => {
    const calls: { name: string; body: Record<string, unknown> }[] = [];
    const database = createClient("https://photo-test.invalid", "test-key", {
      auth: { persistSession: false, autoRefreshToken: false },
      global: {
        fetch: (input, init) => {
          const name = String(input).split("/").pop()!;
          let body: Record<string, unknown> = {};
          try {
            body = JSON.parse(String(init?.body));
          } catch {}
          calls.push({ name, body });
          if (name === "user") {
            return Promise.resolve(
              Response.json({ id: actor, is_anonymous: false }),
            );
          }
          if (name === "invite_request_limit") {
            return Promise.resolve(Response.json(true));
          }
          if (name === "admin_authorize_save") {
            return Promise.resolve(Response.json(null));
          }
          if (name === "admin_avatar_upload_begin") {
            check(
              body.p_actor === actor && body.p_operation === actor,
              "Trusted actor and stable client operation",
            );
            check(/^[a-f0-9]{64}$/.test(String(body.p_hash)), "Content bound");
            return Promise.resolve(
              Response.json({ path: paths[0], upload: !replay }),
            );
          }
          if (name === "admin_save_profile") {
            check(
              (body.p_draft as Record<string, unknown>).avatar_path ===
                paths[0],
              "Exact allocated path finalized",
            );
            return Promise.resolve(
              Response.json({ profile: { id: actor }, replayed: replay }),
            );
          }
          if (String(input).includes("/storage/")) {
            return Promise.resolve(Response.json({ Key: paths[0] }));
          }
          throw Error("Unexpected API " + name);
        },
      },
    });
    const photo = new Uint8Array(24);
    photo.set([137, 80, 78, 71, 13, 10, 26, 10]);
    const response = await handleAdmin(
      new Request("https://photo-test.invalid", {
        method: "POST",
        headers: { Authorization: "Bearer unit-session" },
        body: JSON.stringify({
          action: "save",
          profile_id: actor,
          create: false,
          client_operation_id: actor,
          expected_updated_at: "2026-01-01T00:00:00Z",
          profile: {
            name: "Managed",
            occupation: "Designer",
            summary: "Test",
            skills: ["Design"],
            searching_skills: [],
          },
          photo_base64: btoa(String.fromCharCode(...photo)),
        }),
      }),
      database,
    );
    check(response.status === 200, "Save succeeds");
    const uploadIndex = calls.findIndex((c) => c.name.endsWith(".png"));
    check(
      replay ? uploadIndex === -1 : uploadIndex >
        calls.findIndex((c) => c.name === "admin_avatar_upload_begin"),
      "Lease precedes upload / replay never resurrects file",
    );
  });
}
