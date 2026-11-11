import type { SupabaseClient } from "npm:@supabase/supabase-js@2.108.2";
import {
  type CountryCode,
  isSupportedCountry,
  parsePhoneNumberFromString,
} from "npm:libphonenumber-js@1.13.15/max";
import { decodeBase64, readBody, uuid } from "../push/shared.ts";

type Database = Pick<SupabaseClient, "auth" | "rpc">;
const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, apikey, content-type, x-client-info",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Cache-Control": "no-store",
};
const statuses: Record<string, number> = {
  invalid_request: 400,
  request_too_large: 413,
  membership_required: 403,
  session_revoked: 401,
  identity_changed: 409,
  phone_verification_required: 403,
  phone_changed: 409,
  discovery_state_changed: 409,
  rate_limited: 429,
};
const reply = (status: number, body: unknown) =>
  Response.json(body, { status, headers: cors });
function failure(message: string) {
  const code = Object.hasOwn(statuses, message)
    ? message
    : "server_unavailable";
  return reply(statuses[code] ?? 503, { code });
}

export function normalizePhone(value: string, country?: CountryCode) {
  try {
    const number = parsePhoneNumberFromString(value.trim(), {
      defaultCountry: country,
      extract: false,
    });
    return number?.isValid() && !number.ext ? number.number : null;
  } catch {
    return null;
  }
}

export async function handlePhoneDiscovery(
  request: Request,
  database: Database,
): Promise<Response> {
  if (request.method === "OPTIONS") {
    return new Response(null, { status: 204, headers: cors });
  }
  if (request.method !== "POST") {
    return reply(405, { code: "method_not_allowed" });
  }
  try {
    const body = await readBody(request);
    const actions: Record<string, string[]> = {
      status: [],
      consent: [
        "enabled",
        "expected_phone_revision",
        "expected_consent_revision",
      ],
      lookup: ["phones", "default_country"],
    };
    const action = String(body.action);
    if (
      !Object.hasOwn(actions, action) || !uuid(body.expected_user_id) ||
      Object.keys(body).some((key) =>
        !["action", "expected_user_id", ...actions[action]].includes(key)
      )
    ) return failure("invalid_request");
    if (
      action === "consent" &&
      (typeof body.enabled !== "boolean" ||
        !Object.hasOwn(body, "expected_consent_revision") ||
        (body.expected_consent_revision !== null &&
          !uuid(body.expected_consent_revision)) ||
        (body.enabled &&
          (typeof body.expected_phone_revision !== "string" ||
            !/^[a-f0-9]{64}$/.test(body.expected_phone_revision))))
    ) return failure("invalid_request");
    let country: CountryCode | undefined;
    let phones: (string | null)[] = [];
    if (action === "lookup") {
      if (
        !Array.isArray(body.phones) || body.phones.length < 1 ||
        body.phones.length > 50 ||
        body.phones.some((phone) =>
          typeof phone !== "string" || phone.length > 128
        )
      ) return failure("invalid_request");
      if (body.default_country !== undefined) {
        if (
          typeof body.default_country !== "string" ||
          !isSupportedCountry(body.default_country)
        ) return failure("invalid_request");
        country = body.default_country as CountryCode;
      }
      phones = body.phones.map((phone) => normalizePhone(phone, country));
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
    if (body.expected_user_id !== data.user.id) {
      return failure("identity_changed");
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
    const budget = await database.rpc("invite_request_limit", {
      p_bucket: "phone-discovery:" + data.user.id,
      p_limit: 60,
      p_seconds: 60,
    });
    if (budget.error) return failure("server_unavailable");
    if (!budget.data) return failure("rate_limited");
    const args: Record<string, unknown> = {
      p_user: data.user.id,
      p_session: session,
    };
    if (action === "consent") {
      args.p_enabled = body.enabled;
      args.p_expected_revision = body.enabled
        ? body.expected_phone_revision
        : null;
      args.p_expected_consent_revision = body.expected_consent_revision;
    }
    if (action === "lookup") args.p_phones = phones;
    const result = await database.rpc("phone_discovery_" + action, args);
    if (result.error) return failure(result.error.message);
    if (action === "lookup") {
      return reply(200, {
        ...result.data,
        invalid_indexes: phones.flatMap((phone, index) =>
          phone === null ? [index] : []
        ),
      });
    }
    return reply(200, result.data);
  } catch (error) {
    return failure(
      error instanceof Error ? error.message : "server_unavailable",
    );
  }
}
