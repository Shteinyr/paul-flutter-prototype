import { assert, assertEquals } from "jsr:@std/assert@1.0.19";
import { createClient } from "npm:@supabase/supabase-js@2.108.2";
import { runtimeConfigLoader } from "./runtime_config.ts";
import { type PushConfig } from "./shared.ts";
import { handlePush } from "./handler.ts";

const empty: PushConfig = {
  enabled: false,
  publicKey: "",
  privateKey: "",
  subject: "",
  allowedOrigins: [],
};

Deno.test("independent Edge cold starts share canonical server-generated disabled Vault keys", async () => {
  let settings: Record<string, unknown> | null = null;
  let reads = 0;
  let attempts = 0;
  const client = createClient(
    "https://push-config.invalid",
    "unit-publishable",
    {
      auth: { persistSession: false },
      global: {
        fetch: async (input, init) => {
          const name = new URL(String(input)).pathname.split("/").pop();
          if (name === "push_server_config") {
            reads++;
            return Response.json(settings);
          }
          attempts++;
          const candidate = JSON.parse(String(init?.body)).p_candidate;
          assertEquals(Object.keys(candidate).sort(), [
            "private_key",
            "public_key",
            "worker_secret",
          ]);
          if (!settings) {
            settings = {
              ...candidate,
              enabled: false,
              subject: "https://paul.example.test",
              allowed_origins: ["https://paul.example.test"],
            };
          }
          await new Promise((resolve) => setTimeout(resolve, 2));
          return Response.json(settings);
        },
      },
    },
  );
  const first = runtimeConfigLoader(client, empty, "");
  const second = runtimeConfigLoader(client, empty, "");
  const [a, b, c] = await Promise.all([first(), second(), first()]);
  assertEquals(reads, 2);
  assertEquals(attempts, 2);
  assert(a.publicKey === b.publicKey && a.publicKey === c.publicKey);
  assert(a.privateKey === b.privateKey && a.workerSecret === b.workerSecret);
  assertEquals(a.enabled, false);
  const response = await handlePush(
    new Request("https://push-config.invalid", {
      method: "POST",
      body: '{"action":"config"}',
      headers: { Origin: "https://paul.example.test" },
    }),
    client,
    a,
  );
  assertEquals(await response.json(), {
    version: 1,
    enabled: false,
    vapid_public_key: null,
  });
  settings!.enabled = true;
  const active = await first();
  assertEquals(active.enabled, true);
  assert(
    active.publicKey === a.publicKey && active.privateKey === a.privateKey,
  );
  assertEquals(attempts, 2);
});

Deno.test("complete environment configuration remains explicit and bypasses Vault provisioning", async () => {
  let calls = 0;
  const client = createClient(
    "https://push-config.invalid",
    "unit-publishable",
    {
      auth: { persistSession: false },
      global: {
        fetch: () => {
          calls++;
          throw new Error();
        },
      },
    },
  );
  const environment = {
    ...empty,
    publicKey: "public",
    privateKey: "private",
    subject: "https://paul.example.test",
  };
  const load = runtimeConfigLoader(client, environment, "worker");
  const result = await load();
  assertEquals(result.enabled, false);
  assertEquals(calls, 0);
});
