import { decodeBase64, readBody, uuid } from "../push/shared.ts";
import { type AccountDatabase, cleanupDeletions } from "./cleanup.ts";

const statuses: Record<string, number> = {
  invalid_request: 400,
  request_too_large: 413,
  membership_required: 403,
  session_revoked: 401,
  profile_unavailable: 404,
  deletion_unavailable: 404,
  operation_id_conflict: 409,
  identity_changed: 409,
  account_deleted: 410,
  rate_limited: 429,
};
const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, apikey, content-type, x-client-info",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Cache-Control": "no-store",
};
function reply(status: number, body: unknown) {
  return Response.json(body, { status, headers: cors });
}
async function receiptHash(value: string) {
  const bytes = new Uint8Array(
    await crypto.subtle.digest(
      "SHA-256",
      new TextEncoder().encode(value.toLowerCase()),
    ),
  );
  return Array.from(bytes, (byte) => byte.toString(16).padStart(2, "0")).join(
    "",
  );
}
function failure(message: string) {
  const code = Object.hasOwn(statuses, message)
    ? message
    : "server_unavailable";
  return reply(statuses[code] ?? 503, { code });
}

export async function handleAccount(
  request: Request,
  database: AccountDatabase,
) {
  if (request.method === "OPTIONS") {
    return new Response(null, { status: 204, headers: cors });
  }
  if (request.method !== "POST") {
    return reply(405, { code: "method_not_allowed" });
  }
  try {
    const body = await readBody(request);
    const actions: Record<string, string[]> = {
      capabilities: [],
      profile: ["profile_id"],
      delete: [
        "expected_user_id",
        "client_operation_id",
        "confirm",
        "receipt_token",
      ],
      deletion_status: ["client_operation_id", "receipt_token"],
    };
    const action = String(body.action);
    if (
      !Object.hasOwn(actions, action) ||
      Object.keys(body).some((key) =>
        key !== "action" && !actions[action].includes(key)
      )
    ) {
      return reply(400, { code: "invalid_request" });
    }
    let digest: string | undefined;
    if (action === "delete" || action === "deletion_status") {
      if (
        !uuid(body.client_operation_id) ||
        typeof body.receipt_token !== "string" ||
        !/^[a-f0-9]{64}$/i.test(body.receipt_token) ||
        (action === "delete" &&
          (body.confirm !== true || !uuid(body.expected_user_id)))
      ) {
        return reply(400, { code: "invalid_request" });
      }
      digest = await receiptHash(body.receipt_token);
      const budget = await database.rpc("invite_request_limit", {
        p_bucket: "deletion-recovery:" + body.client_operation_id,
        p_limit: 60,
        p_seconds: 60,
      });
      if (budget.error) return failure("server_unavailable");
      if (!budget.data) return failure("rate_limited");
      const recovered = await database.rpc("account_deletion_status", {
        p_operation: body.client_operation_id,
        p_receipt_hash: digest,
      });
      if (recovered.error) return failure("server_unavailable");
      if (recovered.data) return reply(200, recovered.data);
      if (action === "deletion_status") return failure("deletion_unavailable");
    }
    const bearer = request.headers.get("Authorization")?.match(
      /^Bearer ([^\s]+)$/i,
    )?.[1];
    if (!bearer || bearer.length > 8192) {
      return reply(401, { code: "sign_in_required" });
    }
    const { data, error } = await database.auth.getUser(bearer);
    if (error?.status === 429) return failure("rate_limited");
    if (error && (!error.status || error.status >= 500)) {
      return failure("server_unavailable");
    }
    if (error || !data.user || data.user.is_anonymous) {
      return reply(401, { code: "sign_in_required" });
    }
    let session: unknown;
    try {
      session =
        JSON.parse(new TextDecoder().decode(decodeBase64(bearer.split(".")[1])))
          .session_id;
    } catch {
      return reply(401, { code: "sign_in_required" });
    }
    if (!uuid(session)) return reply(401, { code: "sign_in_required" });
    const args: Record<string, unknown> = {
      p_user: data.user.id,
      p_session: session,
    };
    if (action === "profile") {
      if (!uuid(body.profile_id)) return failure("invalid_request");
      args.p_profile = body.profile_id;
    }
    if (action === "delete") {
      if (body.expected_user_id !== data.user.id) {
        return failure("identity_changed");
      }
      Object.assign(args, {
        p_expected_user: body.expected_user_id,
        p_operation: body.client_operation_id,
        p_receipt_hash: digest,
      });
    }
    const budget = await database.rpc("invite_request_limit", {
      p_bucket: "account:" + data.user.id,
      p_limit: 120,
      p_seconds: 60,
    });
    if (budget.error) return failure("server_unavailable");
    if (!budget.data) return failure("rate_limited");
    const result = await database.rpc(
      action === "delete" ? "member_delete_account" : "member_" + action,
      args,
    );
    if (result.error) return failure(result.error.message);
    if (action === "delete") {
      try {
        await cleanupDeletions(
          database,
          String(body.client_operation_id),
          15000,
        );
      } catch {
        /* The committed operation remains available to the independent worker. */
      }
      const status = await database.rpc("account_deletion_status", {
        p_operation: body.client_operation_id,
        p_receipt_hash: digest,
      });
      return reply(200, status.data ?? result.data);
    }
    return reply(200, result.data);
  } catch (error) {
    return failure(
      error instanceof Error ? error.message : "server_unavailable",
    );
  }
}
