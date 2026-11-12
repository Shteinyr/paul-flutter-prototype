import { authorized } from "../push-worker/handler.ts";
import { readBody } from "../push/shared.ts";
import { type AccountDatabase, cleanupDeletions } from "../account/cleanup.ts";

import { cleanupAvatars } from "../photo-cleanup/cleanup.ts";

export async function handleMaintenance(
  request: Request,
  database: AccountDatabase,
  secret: string,
) {
  const reply = (status: number, body: unknown) =>
    Response.json(body, { status, headers: { "Cache-Control": "no-store" } });
  if (request.method !== "POST") {
    return reply(405, { code: "method_not_allowed" });
  }
  if (!await authorized(request.headers.get("Authorization"), secret)) {
    return reply(401, { code: "sign_in_required" });
  }
  try {
    if (Object.keys(await readBody(request)).length) {
      return reply(400, { code: "invalid_request" });
    }
  } catch {
    return reply(400, { code: "invalid_request" });
  }
  try {
    const started = performance.now();
    const expired = await database.rpc("community_expire", { p_limit: 200 });
    const communityPending = expired.error?.code === "PGRST202";
    const communityError = !!expired.error && !communityPending;
    const cleanup = await cleanupDeletions(database);
    const photos = await cleanupAvatars(
      database,
      Math.max(0, Math.min(8000, 45000 - (performance.now() - started))),
    );
    return reply(
      communityError || cleanup.failed || photos.failed ? 503 : 200,
      {
        community_expired: expired.error ? 0 : expired.data,
        community_pending: communityPending,
        community_error: communityError,
        cleanup,
        photos,
      },
    );
  } catch {
    return reply(503, { code: "server_unavailable" });
  }
}
