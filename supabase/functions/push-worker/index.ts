import { createClient } from "npm:@supabase/supabase-js@2.108.2";
import { handlePushWorker } from "./handler.ts";
import { boundedFetch, loadConfig } from "../push/shared.ts";

const database = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  {
    auth: { persistSession: false, autoRefreshToken: false },
    global: { fetch: boundedFetch },
  },
);
const config = loadConfig();
const secret = Deno.env.get("PAUL_PUSH_WORKER_SECRET") ?? "";
Deno.serve((request) => handlePushWorker(request, database, config, secret));
