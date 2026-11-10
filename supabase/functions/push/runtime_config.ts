import webpush from "npm:web-push@3.6.7";
import { type PushConfig, type PushDatabase } from "./shared.ts";

export interface RuntimeConfig extends PushConfig {
  workerSecret: string;
}

export function runtimeConfigLoader(
  database: PushDatabase,
  environment: PushConfig,
  workerSecret: string,
) {
  let pending: Promise<RuntimeConfig> | undefined;
  async function load(): Promise<RuntimeConfig> {
    if (
      environment.publicKey && environment.privateKey && environment.subject &&
      workerSecret
    ) {
      return { ...environment, workerSecret };
    }
    const current = await database.rpc("push_server_config");
    if (current.error) throw new Error("server_unavailable");
    let settings = current.data;
    if (!settings) {
      const keys = webpush.generateVAPIDKeys();
      const secret = btoa(
        String.fromCharCode(...crypto.getRandomValues(new Uint8Array(32))),
      )
        .replaceAll("+", "-").replaceAll("/", "_").replaceAll("=", "");
      const canonical = await database.rpc("push_provision_config", {
        p_candidate: {
          public_key: keys.publicKey,
          private_key: keys.privateKey,
          worker_secret: secret,
        },
      });
      if (canonical.error || !canonical.data) {
        throw new Error("server_unavailable");
      }
      settings = canonical.data;
    }
    if (
      typeof settings !== "object" ||
      !Array.isArray(settings.allowed_origins) ||
      !/^[A-Za-z0-9_-]{87}$/.test(settings.public_key) ||
      !/^[A-Za-z0-9_-]{43}$/.test(settings.private_key) ||
      !/^[A-Za-z0-9_-]{43}$/.test(settings.worker_secret) ||
      typeof settings.enabled !== "boolean" ||
      typeof settings.subject !== "string" ||
      !settings.allowed_origins.every((origin: unknown) =>
        typeof origin === "string"
      )
    ) {
      throw new Error("server_unavailable");
    }
    return {
      enabled: settings.enabled,
      publicKey: settings.public_key,
      privateKey: settings.private_key,
      subject: settings.subject,
      allowedOrigins: settings.allowed_origins,
      workerSecret: settings.worker_secret,
    };
  }
  return async (): Promise<RuntimeConfig> => {
    if (pending) return pending;
    pending = load();
    try {
      return await pending;
    } finally {
      pending = undefined;
    }
  };
}
