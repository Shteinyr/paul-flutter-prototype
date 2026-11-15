export interface FcmConfig {
  projectId: string;
  clientEmail: string;
  privateKey: string;
}
export interface NativePreparedPush {
  token: string;
  platform: "ios" | "android";
  payload: {
    version: 1;
    delivery_id: string;
    binding_id: string;
    recipient_user_id: string;
    kind: "message_created" | "community_created";
  };
}
export interface NativeDeliveryResult {
  outcome: "sent" | "invalid" | "retry" | "failed";
  code: number;
  retrySeconds: number;
}
const retry = (code = 0, seconds = 30): NativeDeliveryResult => ({
  outcome: "retry",
  code,
  retrySeconds: Math.max(30, Math.min(seconds, 3600)),
});
function base64url(data: Uint8Array): string {
  return btoa(String.fromCharCode(...data)).replaceAll("+", "-").replaceAll(
    "/",
    "_",
  ).replaceAll("=", "");
}
const encoded = (value: unknown) =>
  base64url(new TextEncoder().encode(JSON.stringify(value)));
export class FcmTransport {
  constructor(
    private readonly config: FcmConfig,
    private readonly send: typeof fetch = fetch,
    private readonly now: () => number = Date.now,
  ) {}
  private token: { value: string; expires: number } | null = null;
  private refreshing: Promise<string> | null = null;
  private async accessToken(): Promise<string> {
    if (this.token && this.token.expires > this.now() + 60000) {
      return this.token.value;
    }
    if (this.refreshing) return await this.refreshing;
    const work = this.mint();
    this.refreshing = work;
    try {
      return await work;
    } finally {
      if (this.refreshing === work) this.refreshing = null;
    }
  }
  private async mint(): Promise<string> {
    const issued = Math.floor(this.now() / 1000);
    const head = encoded({ alg: "RS256", typ: "JWT" });
    const claims = encoded({
      iss: this.config.clientEmail,
      scope: "https://www.googleapis.com/auth/firebase.messaging",
      aud: "https://oauth2.googleapis.com/token",
      iat: issued,
      exp: issued + 3600,
    });
    const bytes = Uint8Array.from(
      atob(
        this.config.privateKey.replace(/-----[^-]+-----/g, "").replace(
          /\s/g,
          "",
        ),
      ),
      (char) => char.charCodeAt(0),
    );
    const key = await crypto.subtle.importKey(
      "pkcs8",
      bytes,
      { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
      false,
      ["sign"],
    );
    const content = head + "." + claims;
    const signature = new Uint8Array(
      await crypto.subtle.sign(
        "RSASSA-PKCS1-v1_5",
        key,
        new TextEncoder().encode(content),
      ),
    );
    const response = await this.send("https://oauth2.googleapis.com/token", {
      method: "POST",
      redirect: "error",
      signal: AbortSignal.timeout(5000),
      headers: { "Content-Type": "application/x-www-form-urlencoded" },
      body: new URLSearchParams({
        grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer",
        assertion: content + "." + base64url(signature),
      }),
    });
    if (!response.ok) {
      await response.body?.cancel();
      throw new Error("provider_auth_unavailable");
    }
    const value = await response.json();
    if (
      typeof value.access_token !== "string" || !value.access_token ||
      !Number.isFinite(value.expires_in) || value.expires_in < 60
    ) throw new Error("provider_auth_unavailable");
    this.token = {
      value: value.access_token,
      expires: this.now() + Math.min(value.expires_in, 3600) * 1000,
    };
    return value.access_token;
  }
  async deliver(
    item: NativePreparedPush,
    deadline = Infinity,
  ): Promise<NativeDeliveryResult> {
    if (
      !/^[a-z][a-z0-9-]{4,62}$/.test(this.config.projectId) ||
      !["ios", "android"].includes(item.platform) || item.token.length < 20 ||
      item.token.length > 4096 ||
      !["message_created", "community_created"].includes(item.payload.kind)
    ) return { outcome: "failed", code: 0, retrySeconds: 30 };
    if (performance.now() + 13000 >= deadline) return retry();
    try {
      const bearer = await this.accessToken();
      if (performance.now() + 6500 >= deadline) return retry();
      const payload = item.payload;
      const data = {
        version: "1",
        delivery_id: payload.delivery_id,
        binding_id: payload.binding_id,
        recipient_user_id: payload.recipient_user_id,
        kind: payload.kind,
      };
      const message = {
        // Native clients use firebase_messaging 17 registration APIs. The
        // stored capability is an FID, not a legacy registration token.
        fid: item.token,
        notification: {
          title: "Paul",
          body: payload.kind === "message_created"
            ? "New message"
            : "New Hiring request",
        },
        data,
        android: {
          priority: "high",
          ttl: "300s",
          notification: { tag: payload.delivery_id },
        },
        apns: {
          headers: {
            "apns-push-type": "alert",
            "apns-priority": "10",
            "apns-collapse-id": payload.delivery_id,
            "apns-expiration": String(Math.floor(this.now() / 1000) + 300),
          },
          payload: { aps: { sound: "default" } },
        },
      };
      const response = await this.send(
        `https://fcm.googleapis.com/v1/projects/${this.config.projectId}/messages:send`,
        {
          method: "POST",
          redirect: "error",
          signal: AbortSignal.timeout(5000),
          headers: {
            Authorization: "Bearer " + bearer,
            "Content-Type": "application/json",
          },
          body: JSON.stringify({ message }),
        },
      );
      const status = response.status;
      if (status >= 200 && status < 300) {
        await response.body?.cancel();
        return { outcome: "sent", code: status, retrySeconds: 30 };
      }
      // Only extract a bounded standard error code; provider diagnostics/tokens
      // are neither logged nor returned to callers.
      let code: string | undefined;
      try {
        const reader = response.body?.getReader();
        const parts: Uint8Array[] = [];
        let length = 0;
        if (reader) {
          try {
            while (true) {
              const part = await reader.read();
              if (part.done) break;
              length += part.value.length;
              if (length > 16384) {
                throw new Error("provider_response_too_large");
              }
              parts.push(part.value);
            }
          } finally {
            await reader.cancel();
          }
        }
        const buffer = new Uint8Array(length);
        let offset = 0;
        for (const part of parts) {
          buffer.set(part, offset);
          offset += part.length;
        }
        const text = new TextDecoder().decode(buffer);
        const value = JSON.parse(text);
        code = value.error?.details?.find((
          entry: { "@type"?: string; errorCode?: string },
        ) =>
          entry["@type"] ===
            "type.googleapis.com/google.firebase.fcm.v1.FcmError"
        )?.errorCode;
      } catch { /* Unknown response retains the binding. */ }
      if (code === "UNREGISTERED") {
        return { outcome: "invalid", code: status, retrySeconds: 30 };
      }
      if (status === 401) {
        this.token = null;
        return retry(status);
      }
      if (status === 429 || status >= 500) {
        const header = response.headers.get("Retry-After");
        const seconds = header && /^\d+$/.test(header)
          ? Number(header)
          : header
          ? Math.ceil((Date.parse(header) - this.now()) / 1000)
          : 30;
        return retry(status, Number.isFinite(seconds) ? seconds : 30);
      }
      return { outcome: "failed", code: status, retrySeconds: 30 };
    } catch {
      return retry();
    }
  }
}
