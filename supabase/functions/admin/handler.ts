import type { SupabaseClient } from "npm:@supabase/supabase-js@2.108.2";

import { decodeBase64, uuid as sessionUuid } from "../push/shared.ts";
import { cleanupDeletions } from "../account/cleanup.ts";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, apikey, content-type, x-client-info",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
function reply(status: number, data: unknown) {
  return new Response(JSON.stringify(data), {
    status,
    headers: {
      ...cors,
      "Content-Type": "application/json",
      "Cache-Control": "no-store",
    },
  });
}
const uuid = (value: unknown): value is string =>
  typeof value === "string" &&
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(value);
const statuses: Record<string, number> = {
  admin_forbidden: 403,
  managed_profile_forbidden: 403,
  invalid_request: 400,
  invalid_profile: 400,
  profile_version_conflict: 409,
  operation_id_conflict: 409,
  conversation_forbidden: 403,
  invalid_message: 400,
  message_id_conflict: 409,
  session_revoked: 401,
};
const graphemes = new Intl.Segmenter("en", { granularity: "grapheme" });
export async function handleAdmin(request: Request, database: SupabaseClient) {
  if (request.method === "OPTIONS") {
    return new Response("ok", { headers: cors });
  }
  if (request.method !== "POST") {
    return reply(405, { code: "method_not_allowed" });
  }
  try {
    const bearer = request.headers.get("Authorization")?.match(/^Bearer (.+)$/i)
      ?.[1];
    if (!bearer) return reply(401, { code: "sign_in_required" });
    const { data: auth, error: authError } = await database.auth.getUser(
      bearer,
    );
    if (authError || !auth.user || auth.user.is_anonymous) {
      return reply(401, { code: "sign_in_required" });
    }
    // Bound bytes before accumulation, including requests without Content-Length.
    // This follows the invitation endpoint's bounded reader.
    const reader = request.body?.getReader();
    if (!reader) return reply(400, { code: "invalid_request" });
    const chunks: Uint8Array[] = [];
    let size = 0;
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      size += value.byteLength;
      if (size > 4500000) {
        await reader.cancel();
        return reply(413, { code: "request_too_large" });
      }
      chunks.push(value);
    }
    const bytes = new Uint8Array(size);
    let offset = 0;
    for (const chunk of chunks) {
      bytes.set(chunk, offset);
      offset += chunk.length;
    }
    const raw = new TextDecoder().decode(bytes);
    let body: Record<string, unknown>;
    try {
      const parsed = JSON.parse(raw);
      if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
        throw new Error();
      }
      body = parsed;
    } catch {
      return reply(400, { code: "invalid_request" });
    }
    const fields: Record<string, string[]> = {
      context: [],
      delete: [
        "profile_id",
        "client_operation_id",
        "confirm",
        "expected_updated_at",
      ],
      save: [
        "profile_id",
        "create",
        "client_operation_id",
        "profile",
        "expected_updated_at",
        "photo_base64",
      ],
      status: [
        "profile_id",
        "enabled",
        "client_operation_id",
        "expected_updated_at",
      ],
      inbox: ["profile_id"],
      history: [
        "profile_id",
        "conversation_id",
        "before_seq",
        "after_seq",
        "limit",
      ],
      send: ["profile_id", "conversation_id", "client_message_id", "text"],
      read: ["profile_id", "conversation_id", "through_seq"],
    };
    const action = String(body.action);
    if (
      !Object.hasOwn(fields, action) ||
      Object.keys(body).some((key) =>
        key !== "action" && !fields[action].includes(key)
      )
    ) {
      return reply(400, { code: "invalid_request" });
    }
    const command = action === "save" || action === "status" ||
      action === "delete";
    if (
      action === "delete" &&
      (body.confirm !== true || typeof body.expected_updated_at !== "string")
    ) return reply(400, { code: "invalid_request" });
    if (
      action !== "context" && !(action === "save" && body.create === true) &&
      !uuid(body.profile_id)
    ) return reply(400, { code: "invalid_request" });
    if (
      command &&
      (!uuid(body.client_operation_id) ||
        (body.expected_updated_at != null &&
          (typeof body.expected_updated_at !== "string" ||
            !Number.isFinite(Date.parse(body.expected_updated_at)))))
    ) return reply(400, { code: "invalid_request" });
    if (
      ["history", "send", "read"].includes(action) &&
      !uuid(body.conversation_id)
    ) return reply(400, { code: "invalid_request" });
    const { data: withinBudget, error: budgetError } = await database.rpc(
      "invite_request_limit",
      {
        p_bucket: "admin:" + auth.user.id,
        p_limit: 120,
        p_seconds: 60,
      },
    );
    if (budgetError) return reply(503, { code: "server_unavailable" });
    if (!withinBudget) return reply(429, { code: "rate_limited" });
    const args: Record<string, unknown> = { p_actor: auth.user.id };
    if (action !== "context") args.p_profile = body.profile_id;
    if (command) {
      args.p_client_operation = body.client_operation_id;
      args.p_expected_updated_at = body.expected_updated_at ?? null;
    }
    if (action === "delete") {
      let session: unknown;
      try {
        session = JSON.parse(
          new TextDecoder().decode(decodeBase64(bearer.split(".")[1])),
        ).session_id;
      } catch {
        return reply(401, { code: "sign_in_required" });
      }
      if (!sessionUuid(session)) {
        return reply(401, { code: "sign_in_required" });
      }
      args.p_session = session;
    }
    let rpc = "admin_context";
    if (action === "delete") rpc = "admin_delete_profile";
    if (action === "save") {
      if (
        typeof body.create !== "boolean" || !body.profile ||
        typeof body.profile !== "object" || Array.isArray(body.profile)
      ) {
        return reply(400, { code: "invalid_request" });
      }
      if (body.create && body.profile_id != null) {
        return reply(400, { code: "invalid_request" });
      }
      if (body.create) {
        const { data: reserved, error: reserveError } = await database.rpc(
          "admin_prepare_create",
          {
            p_actor: auth.user.id,
            p_client_operation: body.client_operation_id,
          },
        );
        if (reserveError) {
          return reply(statuses[reserveError.message] ?? 503, {
            code: Object.hasOwn(statuses, reserveError.message)
              ? reserveError.message
              : "server_unavailable",
          });
        }
        if (!uuid(reserved)) return reply(503, { code: "server_unavailable" });
        body.profile_id = reserved;
        args.p_profile = reserved;
      }
      const draft = body.profile as Record<string, unknown>;
      if (
        Object.keys(draft).some((key) =>
          ![
            "name",
            "occupation",
            "summary",
            "skills",
            "searching_skills",
            "avatar_path",
          ].includes(key)
        )
      ) return reply(400, { code: "invalid_profile" });
      if (body.photo_base64 != null) {
        if (
          typeof body.photo_base64 !== "string" ||
          body.photo_base64.length > 4194304
        ) return reply(400, { code: "invalid_profile" });
        let photo: Uint8Array<ArrayBuffer>;
        try {
          photo = Uint8Array.from(
            atob(body.photo_base64),
            (char) => char.charCodeAt(0),
          );
        } catch {
          return reply(400, { code: "invalid_profile" });
        }
        if (
          photo.length < 24 || photo.length > 3 * 1024 * 1024 ||
          ![137, 80, 78, 71, 13, 10, 26, 10].every((byte, index) =>
            photo[index] === byte
          )
        ) return reply(400, { code: "invalid_profile" });
        // Authorization precedes private file upload. The final database command
        // checks it again and atomically stores the selected immutable version.
        const { error: denied } = await database.rpc("admin_authorize_save", {
          p_actor: auth.user.id,
          p_profile: body.profile_id,
          p_create: body.create,
          p_client_operation: body.client_operation_id,
        });
        if (denied) {
          return reply(statuses[denied.message] ?? 503, {
            code: Object.hasOwn(statuses, denied.message)
              ? denied.message
              : "server_unavailable",
          });
        }
        const digest = new Uint8Array(
          await crypto.subtle.digest("SHA-256", photo),
        );
        const hash = Array.from(
          digest,
          (byte) => byte.toString(16).padStart(2, "0"),
        ).join("");
        draft.avatar_path = `${body.profile_id}/${hash}.png`;
        const { error: uploadError } = await database.storage.from("avatars")
          .upload(String(draft.avatar_path), photo, {
            contentType: "image/png",
            upsert: true,
          });
        if (uploadError) return reply(503, { code: "server_unavailable" });
      }
      args.p_create = body.create;
      args.p_draft = draft;
      rpc = "admin_save_profile";
    }
    if (action === "status") {
      if (typeof body.enabled !== "boolean") {
        return reply(400, { code: "invalid_request" });
      }
      args.p_enabled = body.enabled;
      rpc = "admin_set_profile_enabled";
    }
    if (["inbox", "history", "send", "read"].includes(action)) {
      rpc = "operator_" + action;
      if (action !== "inbox") args.p_conversation = body.conversation_id;
    }
    if (action === "history") {
      if (
        (body.before_seq != null &&
          (!Number.isSafeInteger(body.before_seq) ||
            Number(body.before_seq) < 1)) ||
        (body.after_seq != null &&
          (!Number.isSafeInteger(body.after_seq) ||
            Number(body.after_seq) < 0)) ||
        (body.before_seq != null && body.after_seq != null) ||
        (body.limit != null &&
          (!Number.isInteger(body.limit) || Number(body.limit) < 1 ||
            Number(body.limit) > 100))
      ) return reply(400, { code: "invalid_request" });
      args.p_before = body.before_seq ?? null;
      args.p_after = body.after_seq ?? null;
      args.p_limit = body.limit ?? 50;
    }
    if (action === "send") {
      if (
        !uuid(body.client_message_id) || typeof body.text !== "string" ||
        !body.text.trim() || body.text.includes("\0") ||
        Array.from(graphemes.segment(body.text)).length > 2000 ||
        new TextEncoder().encode(body.text).length > 65536
      ) return reply(400, { code: "invalid_message" });
      args.p_client_message = body.client_message_id;
      args.p_text = body.text;
    }
    if (action === "read") {
      if (
        !Number.isSafeInteger(body.through_seq) || Number(body.through_seq) < 0
      ) return reply(400, { code: "invalid_request" });
      args.p_through = body.through_seq;
    }
    const { data, error } = await database.rpc(rpc, args);
    if (error) {
      const code = Object.hasOwn(statuses, error.message)
        ? error.message
        : "server_unavailable";
      return reply(statuses[code] ?? 503, { code });
    }
    if (action === "delete") {
      try {
        await cleanupDeletions(
          database,
          String(body.client_operation_id),
          15000,
        );
      } catch { /* Durable cleanup proceeds without the UI session. */ }
      const status = await database.rpc("admin_delete_profile", args);
      return reply(200, status.data ?? data);
    }
    return reply(200, data);
  } catch {
    // Never log profile data, auth credentials, or database internals.
    return reply(503, { code: "server_unavailable" });
  }
}
