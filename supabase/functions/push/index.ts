import { createClient } from "npm:@supabase/supabase-js@2.108.2";
import { handlePush } from "./handler.ts";
import { boundedFetch, loadConfig } from "./shared.ts";

const database = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  {
    auth: { persistSession: false, autoRefreshToken: false },
    global: { fetch: boundedFetch },
  },
);
const config = loadConfig();
Deno.serve((request) => handlePush(request, database, config));
