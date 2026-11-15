import { createClient } from "@supabase/supabase-js";
import { boundedFetch } from "../push/shared.ts";
import { handleNativePush } from "./handler.ts";
const database = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  {
    auth: { persistSession: false, autoRefreshToken: false },
    global: { fetch: boundedFetch },
  },
);
Deno.serve((request) => handleNativePush(request, database));
