import { createClient } from "npm:@supabase/supabase-js@2.108.2";
import { handleSkillSearch } from "./handler.ts";

const url = Deno.env.get("SUPABASE_URL")!;
const options = { auth: { persistSession: false, autoRefreshToken: false } };
const service = createClient(
  url,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  options,
);

Deno.serve((request) =>
  handleSkillSearch(
    request,
    service,
    (token) =>
      createClient(url, Deno.env.get("SUPABASE_ANON_KEY")!, {
        ...options,
        global: { headers: { Authorization: `Bearer ${token}` } },
      }),
  )
);
