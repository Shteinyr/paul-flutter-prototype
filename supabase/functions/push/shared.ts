import type { SupabaseClient } from "npm:@supabase/supabase-js@2.108.2";

export type PushDatabase = Pick<SupabaseClient, "auth" | "rpc">;
export interface PushConfig {
  enabled: boolean;
  publicKey: string;
  privateKey: string;
  subject: string;
  allowedOrigins: string[];
}

export const uuid = (value: unknown): value is string =>
  typeof value === "string" &&
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i
    .test(value);

export function validEndpoint(value: unknown): value is string {
  if (typeof value !== "string" || value.length > 2048) return false;
  try {
    const url = new URL(value);
    if (
      url.protocol !== "https:" || url.port || url.username || url.password ||
      url.search || url.hash || url.href !== value
    ) return false;
    return (url.hostname === "fcm.googleapis.com" &&
      /^\/(fcm\/send|wp)\/.+/.test(url.pathname)) ||
      (url.hostname === "updates.push.services.mozilla.com" &&
        /^\/wpush\/.+/.test(url.pathname)) ||
      (url.hostname === "web.push.apple.com" && url.pathname.length > 1);
  } catch {
    return false;
  }
}

export function decodeBase64(value: string): Uint8Array<ArrayBuffer> {
  return Uint8Array.from(
    atob(value.replace(/-/g, "+").replace(/_/g, "/")),
    (c) => c.charCodeAt(0),
  );
}

export async function validKeys(keys: unknown): Promise<boolean> {
  if (!keys || typeof keys !== "object" || Array.isArray(keys)) return false;
  const item = keys as Record<string, unknown>;
  if (
    Object.keys(item).some((key) => !["p256dh", "auth"].includes(key)) ||
    typeof item.p256dh !== "string" ||
    !/^[A-Za-z0-9_-]{87}$/.test(item.p256dh) ||
    typeof item.auth !== "string" || !/^[A-Za-z0-9_-]{22}$/.test(item.auth)
  ) return false;
  try {
    const publicKey = decodeBase64(item.p256dh);
    if (
      publicKey.length !== 65 || publicKey[0] !== 4 ||
      decodeBase64(item.auth).length !== 16
    ) return false;
    await crypto.subtle.importKey(
      "raw",
      publicKey,
      { name: "ECDH", namedCurve: "P-256" },
      false,
      [],
    );
    return true;
  } catch {
    return false;
  }
}

export async function readBody(
  request: Request,
): Promise<Record<string, unknown>> {
  const reader = request.body?.getReader();
  if (!reader) throw new Error("invalid_request");
  const parts: Uint8Array[] = [];
  let size = 0;
  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    size += value.length;
    if (size > 8192) {
      await reader.cancel();
      throw new Error("request_too_large");
    }
    parts.push(value);
  }
  const bytes = new Uint8Array(size);
  let offset = 0;
  for (const part of parts) {
    bytes.set(part, offset);
    offset += part.length;
  }
  let body;
  try {
    body = JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(bytes));
  } catch {
    throw new Error("invalid_request");
  }
  if (!body || typeof body !== "object" || Array.isArray(body)) {
    throw new Error("invalid_request");
  }
  return body;
}

export const errors: Record<string, number> = {
  invalid_request: 400,
  request_too_large: 413,
  sign_in_required: 401,
  session_revoked: 401,
  membership_required: 403,
  push_forbidden: 403,
  binding_conflict: 409,
  rate_limited: 429,
};

export const boundedFetch: typeof fetch = (input, init = {}) => {
  const signals = [AbortSignal.timeout(5000)];
  if (init.signal) signals.push(init.signal);
  return fetch(input, {
    ...init,
    signal: AbortSignal.any(signals),
    redirect: "error",
  });
};

export function loadConfig(): PushConfig {
  return {
    enabled: Deno.env.get("PAUL_PUSH_ENABLED") === "true",
    publicKey: Deno.env.get("PAUL_VAPID_PUBLIC_KEY") ?? "",
    privateKey: Deno.env.get("PAUL_VAPID_PRIVATE_KEY") ?? "",
    subject: Deno.env.get("PAUL_VAPID_SUBJECT") ?? "",
    allowedOrigins: (Deno.env.get("PAUL_PUSH_ALLOWED_ORIGINS") ?? "").split(",")
      .filter(Boolean),
  };
}
