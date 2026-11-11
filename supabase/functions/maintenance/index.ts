import { createClient } from "npm:@supabase/supabase-js@2.108.2";
import { boundedFetch, loadConfig } from "../push/shared.ts";
import { runtimeConfigLoader } from "../push/runtime_config.ts";
import { handleMaintenance } from "./handler.ts";

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
    return await handleMaintenance(
      request,
      database,
      (await config()).workerSecret,
    );
  } catch {
    return Response.json({ code: "server_unavailable" }, {
      status: 503,
      headers: { "Cache-Control": "no-store" },
    });
  }
});
