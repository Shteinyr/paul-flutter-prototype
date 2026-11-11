import {
  type PushConfig,
  type PushDatabase,
  readBody,
} from "../push/shared.ts";
import { deliverPush, type PreparedPush } from "../push/transport.ts";

export async function authorized(
  value: string | null,
  secret: string,
): Promise<boolean> {
  if (!value || secret.length < 32 || value.length > 512) return false;
  const hash = async (text: string) =>
    new Uint8Array(
      await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text)),
    );
  const [actual, expected] = await Promise.all([
    hash(value),
    hash("Bearer " + secret),
  ]);
  let different = 0;
  for (let i = 0; i < actual.length; i++) different |= actual[i] ^ expected[i];
  return different === 0;
}

export async function handlePushWorker(
  request: Request,
  database: PushDatabase,
  config: PushConfig,
  secret: string,
  send: typeof fetch = fetch,
): Promise<Response> {
  const reply = (status: number, body: unknown) =>
    new Response(JSON.stringify(body), {
      status,
      headers: {
        "Content-Type": "application/json",
        "Cache-Control": "no-store",
      },
    });
  if (request.method !== "POST") {
    return reply(405, { code: "method_not_allowed" });
  }
  if (!await authorized(request.headers.get("Authorization"), secret)) {
    return reply(401, { code: "sign_in_required" });
  }
  if (
    !config.enabled || !config.publicKey || !config.privateKey ||
    !config.subject
  ) return reply(503, { code: "server_unavailable" });
  try {
    if (Object.keys(await readBody(request)).length) {
      return reply(400, { code: "invalid_request" });
    }
  } catch {
    return reply(400, { code: "invalid_request" });
  }
  const counts = {
    claimed: 0,
    sent: 0,
    invalid: 0,
    retry: 0,
    failed: 0,
    cancelled: 0,
  };
  try {
    const { data, error } = await database.rpc("push_claim", { p_limit: 4 });
    if (error || !Array.isArray(data)) throw new Error();
    const claims = data as { delivery_id: string; lease_token: string }[];
    counts.claimed = claims.length;
    let index = 0;
    const deadline = Date.now() + 45000;
    async function run() {
      while (index < claims.length && Date.now() < deadline) {
        const claim = claims[index++];
        const args = {
          p_delivery: claim.delivery_id,
          p_lease: claim.lease_token,
        };
        try {
          const started = performance.now();
          const prepared = await database.rpc("push_prepare", args);
          if (prepared.error) throw new Error();
          if (!prepared.data) {
            counts.cancelled++;
            continue;
          }
          const leaseRemaining = Number(prepared.data.lease_remaining_ms);
          if (!Number.isFinite(leaseRemaining) || leaseRemaining > 30000) {
            throw new Error();
          }
          const result = await deliverPush(
            prepared.data as PreparedPush,
            config,
            send,
            started + leaseRemaining,
          );
          const finished = await database.rpc("push_finish", {
            ...args,
            p_outcome: result.outcome,
            p_code: result.code,
            p_retry_seconds: result.retrySeconds,
          });
          if (finished.error) throw new Error();
          if (finished.data === true) counts[result.outcome]++;
          else counts.cancelled++;
        } catch {
          // Leave the fence leased when the outcome cannot be confirmed. A later
          // bounded claim rechecks authorization and recovers after lease expiry.
          counts.failed++;
        }
      }
    }
    await Promise.all([run(), run()]);
    return reply(200, counts);
  } catch {
    return reply(503, { code: "server_unavailable" });
  }
}
