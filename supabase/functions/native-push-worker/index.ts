import { createClient } from "@supabase/supabase-js";
import { boundedFetch } from "../push/shared.ts";
import { FcmTransport } from "./transport.ts";
import { handleNativePushWorker } from "./handler.ts";
const database = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  {
    auth: { persistSession: false, autoRefreshToken: false },
    global: { fetch: boundedFetch },
  },
);
const projectId = Deno.env.get("PAUL_FCM_PROJECT_ID") ?? "";
const clientEmail = Deno.env.get("PAUL_FCM_CLIENT_EMAIL") ?? "";
const privateKey = (Deno.env.get("PAUL_FCM_PRIVATE_KEY") ?? "").replaceAll(
  "\\n",
  "\n",
);
const transport =
  Deno.env.get("PAUL_NATIVE_PUSH_ENABLED") === "true" && projectId &&
    clientEmail && privateKey
    ? new FcmTransport({ projectId, clientEmail, privateKey }, boundedFetch)
    : null;
const secret = Deno.env.get("PAUL_NATIVE_PUSH_WORKER_SECRET") ?? "";
Deno.serve((request) =>
  handleNativePushWorker(request, database, transport, secret)
);
