import { createClient } from "npm:@supabase/supabase-js@2.108.2";
import { handlePublicPreview } from "./handler.ts";
const service = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  { auth: { persistSession: false, autoRefreshToken: false } },
);
Deno.serve((request) =>
  handlePublicPreview(request, service, async (paths) => {
    const { data, error } = await service.storage.from("avatars")
      .createSignedUrls(paths, 60);
    if (error) throw error;
    return new Map(
      (data ?? []).filter((p) => p.path && p.signedUrl).map(
        (p) => [p.path!, p.signedUrl!],
      ),
    );
  })
);
