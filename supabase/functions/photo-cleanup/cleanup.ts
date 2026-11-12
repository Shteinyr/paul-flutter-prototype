import type { SupabaseClient } from "npm:@supabase/supabase-js@2.108.2";
type Database = Pick<SupabaseClient, "rpc" | "storage">;
const pathPattern =
  /^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}\/[a-f0-9]{64}[.]png$/;
const leasePattern = /^[a-f0-9-]{36}$/i;

export async function cleanupAvatars(database: Database, budgetMs = 8000) {
  const counts = {
    claimed: 0,
    complete: 0,
    retry: 0,
    cancelled: 0,
    failed: 0,
    pending: false,
  };
  const deadline = performance.now() + budgetMs;
  const claim = await database.rpc("avatar_cleanup_claim", { p_limit: 5 });
  // Allow reviewed schema and Edge deployment in either order. SQL defaults OFF.
  if (claim.error?.code === "PGRST202") return { ...counts, pending: true };
  if (claim.error || !Array.isArray(claim.data)) {
    throw new Error("server_unavailable");
  }
  for (const job of claim.data) {
    if (
      !job || typeof job.path !== "string" || !pathPattern.test(job.path) ||
      typeof job.lease_token !== "string" || !leasePattern.test(job.lease_token)
    ) {
      counts.failed++;
      continue;
    }
    counts.claimed++;
    const args = { p_path: job.path, p_lease: job.lease_token };
    async function finish(success: boolean) {
      const result = await database.rpc("avatar_cleanup_finish", {
        ...args,
        p_success: success,
      });
      if (result.error) throw new Error("server_unavailable");
      if (!result.data) counts.cancelled++;
      else if (result.data.state === "deleted") counts.complete++;
      else counts.retry++;
    }
    try {
      if (performance.now() > deadline - 2000) {
        await finish(false);
        continue;
      }
      // This commits the irrevocable per-path fence before any external DELETE.
      const prepared = await database.rpc("avatar_cleanup_prepare", args);
      if (prepared.error) throw new Error("server_unavailable");
      if (!prepared.data) {
        counts.cancelled++;
        continue;
      }
      if (
        prepared.data.path !== job.path ||
        typeof prepared.data.exists !== "boolean"
      ) {
        throw new Error("server_unavailable");
      }
      if (performance.now() > deadline - 2000) {
        await finish(false);
        continue;
      }
      if (prepared.data.exists) {
        const removed = await database.storage.from("avatars").remove([
          job.path,
        ]);
        if (removed.error && String(removed.error.statusCode) !== "404") {
          await finish(false);
          continue;
        }
      }
      await finish(true);
    } catch {
      // Unknown DELETE/finish commits retry only the same permanently retired path.
      try {
        await finish(false);
      } catch {
        counts.failed++;
      }
    }
  }
  return counts;
}
