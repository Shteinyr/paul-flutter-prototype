import { createClient } from "npm:@supabase/supabase-js@2.108.2";
import { handlePush } from "./handler.ts";
import { boundedFetch, loadConfig } from "./shared.ts";
import { runtimeConfigLoader } from "./runtime_config.ts";

const database = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  {
    auth: { persistSession: false, autoRefreshToken: false },
    global: { fetch: boundedFetch },
  },
);
const config = runtimeConfigLoader(
  database,
  loadConfig(),
  Deno.env.get("PAUL_PUSH_WORKER_SECRET") ?? "",
);
Deno.serve(async (request) => {
  try {
    return await handlePush(request, database, await config());
  } catch {
    return Response.json({ code: "server_unavailable" }, {
      status: 503,
      headers: {
        "Access-Control-Allow-Origin": "*",
        "Cache-Control": "no-store",
      },
    });
  }
});
