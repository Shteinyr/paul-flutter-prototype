import { createClient } from "npm:@supabase/supabase-js@2.108.2";

import { decodeBase64, uuid as sessionUuid } from "../push/shared.ts";

const url = Deno.env.get("SUPABASE_URL")!;
const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const database = createClient(url, serviceKey, {
  auth: { persistSession: false, autoRefreshToken: false },
});
const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, apikey, content-type, x-client-info",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function reply(status: number, body: unknown) {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      ...cors,
      "Content-Type": "application/json",
      "Cache-Control": "no-store",
    },
  });
}

async function digest(value: string): Promise<string> {
  const bytes = await crypto.subtle.digest(
    "SHA-256",
    new TextEncoder().encode(value),
  );
  return Array.from(
    new Uint8Array(bytes),
    (byte) => byte.toString(16).padStart(2, "0"),
  ).join("");
}

async function limit(bucket: string, count: number, seconds: number) {
  const { data, error } = await database.rpc("invite_request_limit", {
    p_bucket: bucket,
    p_limit: count,
    p_seconds: seconds,
  });
  if (error) throw new Error("server_unavailable");
  if (!data) throw new Error("rate_limited");
}

const graphemes = new Intl.Segmenter("en", { granularity: "grapheme" });
function graphemeLength(value: string): number {
  return Array.from(graphemes.segment(value)).length;
}

function profileValid(value: unknown): boolean {
  if (!value || typeof value !== "object" || Array.isArray(value)) return false;
  const p = value as Record<string, unknown>;
  const text = (key: string, max: number, required = true) =>
    typeof p[key] === "string" &&
    (!required || (p[key] as string).trim().length > 0) &&
    graphemeLength(p[key] as string) <= max;
  const skills = (value: unknown, required: boolean) => {
    if (!Array.isArray(value)) return false;
    const normalized = value.map((skill) =>
      typeof skill === "string"
        ? skill.trim().replace(/\s+/gu, " ").toLowerCase()
        : skill
    );
    return new Set(normalized).size === value.length &&
      value.length >= (required ? 1 : 0) && (required || value.length <= 100) &&
      value.every((s) =>
        typeof s === "string" && s.trim().length > 0 && graphemeLength(s) <= 64
      );
  };
  return text("name", 120) && text("occupation", 120, false) &&
    text("summary", 500) &&
    skills(p.skills, true) && skills(p.searching_skills, false) &&
    (p.avatar_path == null || typeof p.avatar_path === "string");
}

Deno.serve(async (request) => {
  if (request.method === "OPTIONS") {
    return new Response(null, { headers: cors });
  }
  if (request.method !== "POST") {
    return reply(405, { code: "method_not_allowed" });
  }
  try {
    // Bound parsing, including requests sent without a Content-Length header.
    const reader = request.body?.getReader();
    if (!reader) return reply(400, { code: "invalid_request" });
    const chunks: Uint8Array[] = [];
    let size = 0;
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      size += value.byteLength;
      if (size > 32768) {
        await reader.cancel();
        return reply(413, { code: "invalid_request" });
      }
      chunks.push(value);
    }
    const bytes = new Uint8Array(size);
    let offset = 0;
    for (const chunk of chunks) {
      bytes.set(chunk, offset);
      offset += chunk.length;
    }
    let body: Record<string, unknown>;
    try {
      body = JSON.parse(new TextDecoder().decode(bytes));
    } catch {
      return reply(400, { code: "invalid_request" });
    }
    if (!body || typeof body !== "object" || Array.isArray(body)) {
      return reply(400, { code: "invalid_request" });
    }
    if (
      body.profile && typeof body.profile === "object" &&
      !Array.isArray(body.profile)
    ) {
      const profile = body.profile as Record<string, unknown>;
      for (const key of ["skills", "searching_skills"]) {
        if (Array.isArray(profile[key])) {
          profile[key] = (profile[key] as unknown[]).map((skill) =>
            typeof skill === "string"
              ? skill.trim().replace(/\s+/gu, " ")
              : skill
          );
        }
      }
    }
    const action = body.action;
    if (
      !["check", "issue", "redeem", "revoke", "save_profile", "network"]
        .includes(
          String(action),
        )
    ) {
      return reply(400, { code: "invalid_request" });
    }

    // Global and per-source budgets both apply. Tokens and raw IPs are never stored.
    await limit("all", 1200, 60);
    const address =
      request.headers.get("x-forwarded-for")?.split(",")[0]?.trim() ??
        "unknown";
    const source = await digest(serviceKey + ":source:" + address);
    await limit("source:" + source, 60, 60);
    if (action === "check" || action === "redeem") {
      await limit("lookup:" + source, 20, 60);
    }

    let userId: string | undefined;
    if (action !== "check") {
      const bearer = request.headers.get("Authorization")?.match(
        /^Bearer (.+)$/i,
      )?.[1];
      if (!bearer) return reply(401, { code: "sign_in_required" });
      const { data, error } = await database.auth.getUser(bearer);
      if (error || !data.user || data.user.is_anonymous) {
        return reply(401, { code: "sign_in_required" });
      }
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
      const sessionCheck = await database.rpc("member_require_auth_session", {
        p_user: data.user.id,
        p_session: session,
      });
      if (sessionCheck.error) {
        return reply(
          sessionCheck.error.message === "session_revoked" ? 401 : 503,
          {
            code: sessionCheck.error.message === "session_revoked"
              ? "session_revoked"
              : "server_unavailable",
          },
        );
      }
      userId = data.user.id;
      await limit("user:" + userId, 60, 60);
    }

    let rpc: string;
    let args: Record<string, unknown>;
    let code: string | undefined;
    if (action === "issue") {
      if (
        typeof body.token !== "string" || !/^[a-f0-9]{64}$/.test(body.token)
      ) return reply(400, { code: "invalid_request" });
      const codeDigest = await digest("manual:" + body.token);
      code = (parseInt(codeDigest.slice(0, 12), 16) % 100000000).toString()
        .padStart(8, "0");
      rpc = "issue_invitation";
      args = {
        p_user: userId,
        p_token_hash: await digest("token:" + body.token),
        p_code_hash: await digest(serviceKey + ":code:" + code),
      };
    } else if (action === "revoke") {
      if (typeof body.id !== "string" || !/^[a-f0-9-]{36}$/.test(body.id)) {
        return reply(400, { code: "invalid_request" });
      }
      rpc = "revoke_invitation";
      args = { p_user: userId, p_invitation: body.id };
    } else if (action === "network") {
      rpc = "member_network";
      args = { p_user: userId };
    } else if (action === "save_profile") {
      if (!profileValid(body.profile)) {
        return reply(400, { code: "invalid_profile" });
      }
      rpc = "save_member_profile";
      args = { p_user: userId, p_profile: body.profile };
    } else {
      const credential = body.credential;
      if (
        typeof credential !== "string" ||
        !/^(?:[a-f0-9]{64}|[0-9]{8})$/.test(credential)
      ) {
        return reply(400, { code: "invalid_invitation" });
      }
      const manual = credential.length === 8;
      rpc = action === "check" ? "check_invitation" : "redeem_invitation";
      args = {
        p_hash: await digest(
          manual ? serviceKey + ":code:" + credential : "token:" + credential,
        ),
        p_manual: manual,
      };
      if (action === "redeem") {
        // Existing members may connect without supplying a registration draft.
        if (body.profile != null && !profileValid(body.profile)) {
          return reply(400, { code: "invalid_profile" });
        }
        args.p_user = userId;
        args.p_profile = body.profile ?? {};
      }
    }
    const { data, error } = await database.rpc(rpc, args);
    if (error) {
      if (error.code === "23505" && action === "issue") {
        return reply(409, { code: "invitation_collision" });
      }
      const known = [
        "invalid_invitation",
        "own_invitation",
        "membership_required",
        "invalid_profile",
        "offering_limit_reached",
        "account_deleted",
        "rate_limited",
      ];
      const problem = known.find((value) => error.message === value);
      if (problem) {
        return reply(
          problem === "rate_limited"
            ? 429
            : problem === "account_deleted"
            ? 410
            : problem === "offering_limit_reached"
            ? 403
            : 400,
          { code: problem },
        );
      }
      // Do not include SQL, identifiers, credentials or internal errors in responses/logs.
      return reply(503, { code: "server_unavailable" });
    }
    return reply(200, { ...data, ...(code ? { code } : {}) });
  } catch (error) {
    if (error instanceof Error && error.message === "rate_limited") {
      return reply(429, { code: "rate_limited" });
    }
    return reply(503, { code: "server_unavailable" });
  }
});
