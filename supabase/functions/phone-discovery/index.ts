import { createClient } from "npm:@supabase/supabase-js@2.108.2";
import { boundedFetch } from "../push/shared.ts";
import { handlePhoneDiscovery } from "./handler.ts";

const database = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  {
    auth: { persistSession: false, autoRefreshToken: false },
    global: { fetch: boundedFetch },
  },
);
Deno.serve((request) => handlePhoneDiscovery(request, database));
