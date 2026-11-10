import webpush from "npm:web-push@3.6.7";
import { type PushConfig, validEndpoint } from "./shared.ts";

export interface PreparedPush {
  endpoint: string;
  keys: { p256dh: string; auth: string };
  payload: {
    version: 1;
    delivery_id: string;
    binding_id: string;
    recipient_user_id: string;
  };
}
export interface DeliveryResult {
  outcome: "sent" | "invalid" | "retry" | "failed";
  code: number;
  retrySeconds: number;
}

export async function deliverPush(
  item: PreparedPush,
  config: PushConfig,
  send: typeof fetch = fetch,
  deadline = Infinity,
): Promise<DeliveryResult> {
  if (!validEndpoint(item.endpoint)) {
    return { outcome: "failed", code: 0, retrySeconds: 30 };
  }
  const details = webpush.generateRequestDetails(
    { endpoint: item.endpoint, keys: item.keys },
    JSON.stringify(item.payload),
    {
      vapidDetails: {
        publicKey: config.publicKey,
        privateKey: config.privateKey,
        subject: config.subject,
      },
      contentEncoding: "aes128gcm",
      TTL: 300,
      urgency: "normal",
      topic: item.payload.delivery_id.replaceAll("-", ""),
    },
  );
  if (performance.now() + 11000 >= deadline) {
    return { outcome: "retry", code: 0, retrySeconds: 30 };
  }
  try {
    const response = await send(item.endpoint, {
      method: "POST",
      headers: details.headers,
      body: new Uint8Array(details.body),
      redirect: "error",
      signal: AbortSignal.timeout(5000),
    });
    // Provider response bodies can contain endpoint credentials. Never read or log.
    await response.body?.cancel();
    const code = response.status;
    if (code >= 200 && code < 300) {
      return { outcome: "sent", code, retrySeconds: 30 };
    }
    if (code === 404 || code === 410) {
      return { outcome: "invalid", code, retrySeconds: 30 };
    }
    let retrySeconds = 30;
    const retryAfter = response.headers.get("Retry-After");
    if (retryAfter) {
      const seconds = /^\d+$/.test(retryAfter)
        ? Number(retryAfter)
        : Math.ceil((Date.parse(retryAfter) - Date.now()) / 1000);
      if (Number.isFinite(seconds)) {
        retrySeconds = Math.max(30, Math.min(seconds, 3600));
      }
    }
    return {
      outcome: code === 429 || code >= 500 ? "retry" : "failed",
      code,
      retrySeconds,
    };
  } catch {
    // An unknown commit is retried with the same delivery ID/topic. The SW also
    // deduplicates it, since exactly-once delivery cannot span an external HTTP call.
    return { outcome: "retry", code: 0, retrySeconds: 30 };
  }
}
