import type { PushDatabase } from "../push/shared.ts";
import { readBody } from "../push/shared.ts";
import { authorized } from "./worker_auth.ts";
import { FcmTransport, type NativePreparedPush } from "./transport.ts";

export async function handleNativePushWorker(
  request: Request,
  database: PushDatabase,
  transport: Pick<FcmTransport, "deliver"> | null,
  secret: string,
): Promise<Response> {
  const reply = (status: number, body: unknown) =>
    Response.json(body, { status, headers: { "Cache-Control": "no-store" } });
  if (request.method !== "POST") {
    return reply(405, { code: "method_not_allowed" });
  }
  if (!await authorized(request.headers.get("Authorization"), secret)) {
    return reply(401, { code: "sign_in_required" });
  }
  if (!transport) return reply(503, { code: "server_unavailable" });
  try {
    let body: Record<string, unknown>;
    try {
      body = await readBody(request);
    } catch (error) {
      const oversized = error instanceof Error &&
        error.message === "request_too_large";
      return reply(oversized ? 413 : 400, {
        code: oversized ? "request_too_large" : "invalid_request",
      });
    }
    if (Object.keys(body).length) {
      return reply(400, { code: "invalid_request" });
    }
    const claimed = await database.rpc("native_push_claim", { p_limit: 4 });
    if (claimed.error || !Array.isArray(claimed.data)) throw new Error();
    const counts = {
      claimed: claimed.data.length,
      sent: 0,
      invalid: 0,
      retry: 0,
      failed: 0,
      cancelled: 0,
    };
    let index = 0;
    const deadline = performance.now() + 45000;
    const run = async () => {
      while (index < claimed.data.length && performance.now() < deadline) {
        const claim = claimed.data[index++];
        const args = {
          p_delivery: claim.delivery_id,
          p_lease: claim.lease_token,
        };
        try {
          const started = performance.now();
          const prepared = await database.rpc("native_push_prepare", args);
          if (prepared.error) throw new Error();
          if (!prepared.data) {
            counts.cancelled++;
            continue;
          }
          const remaining = Number(prepared.data.lease_remaining_ms);
          if (
            !Number.isFinite(remaining) || remaining <= 0 || remaining > 30000
          ) throw new Error();
          const result = await transport.deliver(
            prepared.data as NativePreparedPush,
            started + remaining,
          );
          const finished = await database.rpc("native_push_finish", {
            ...args,
            p_outcome: result.outcome,
            p_code: result.code,
            p_retry_seconds: result.retrySeconds,
          });
          if (finished.error) throw new Error();
          if (finished.data === true) counts[result.outcome]++;
          else counts.cancelled++;
        } catch {
          counts.failed++;
        }
      }
    };
    await Promise.all([run(), run()]);
    return reply(200, counts);
  } catch {
    return reply(503, { code: "server_unavailable" });
  }
}
