import { handleAdmin } from "./handler.ts";
import { createClient } from "npm:@supabase/supabase-js@2.108.2";

const database = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  { auth: { persistSession: false, autoRefreshToken: false } },
);

Deno.serve((request) => handleAdmin(request, database));
