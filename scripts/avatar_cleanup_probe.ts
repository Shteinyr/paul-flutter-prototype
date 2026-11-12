import { createClient } from "npm:@supabase/supabase-js@2.108.2";
import { cleanupAvatars } from "../supabase/functions/photo-cleanup/cleanup.ts";
const url = Deno.args[0];
if (!/^http:\/\/127[.]0[.]0[.]1:[0-9]+$/.test(url)) {
  throw Error("Local fixture only");
}
const database = createClient(url, "local-fixture-only", {
  auth: { persistSession: false, autoRefreshToken: false },
});
console.log(JSON.stringify(await cleanupAvatars(database, 15000)));
