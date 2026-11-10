import { createClient } from "npm:@supabase/supabase-js@2.108.2";
import { handlePushWorker } from "./handler.ts";
import { boundedFetch, loadConfig } from "../push/shared.ts";
import { runtimeConfigLoader } from "../push/runtime_config.ts";

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
    const settings = await config();
    return await handlePushWorker(
      request,
      database,
      settings,
      settings.workerSecret,
    );
  } catch {
    return Response.json({ code: "server_unavailable" }, {
      status: 503,
      headers: { "Cache-Control": "no-store" },
    });
  }
});
