import type { SupabaseClient } from "npm:@supabase/supabase-js@2.108.2";

export type AccountDatabase = Pick<SupabaseClient, "rpc" | "auth" | "storage">;
interface CleanupClaim {
  operation_id: string;
  lease_token: string;
}
interface CleanupPreparation {
  objects: { bucket: string; name: string }[];
  auth_user_id: string | null;
}

export async function cleanupDeletions(
  database: AccountDatabase,
  operation: string | null = null,
  budgetMs = 35000,
) {
  const counts = { claimed: 0, complete: 0, retry: 0, cancelled: 0, failed: 0 };
  const deadline = performance.now() + budgetMs;
  const claim = await database.rpc("account_cleanup_claim", {
    p_operation: operation,
    p_limit: operation ? 1 : 2,
  });
  if (claim.error || !Array.isArray(claim.data)) {
    throw new Error("server_unavailable");
  }
  const claims = claim.data as CleanupClaim[];
  counts.claimed = claims.length;
  for (const job of claims) {
    const args = { p_operation: job.operation_id, p_lease: job.lease_token };
    async function finish(success: boolean, error: string | null = null) {
      const result = await database.rpc("account_cleanup_finish", {
        ...args,
        p_success: success,
        p_error: error,
      });
      if (result.error) throw new Error("server_unavailable");
      if (!result.data) counts.cancelled++;
      else if (result.data.state === "complete") counts.complete++;
      else counts.retry++;
    }
    try {
      let finished = false;
      for (
        let batch = 0;
        batch < 8 && performance.now() < deadline - 5000;
        batch++
      ) {
        const preparation = await database.rpc("account_cleanup_prepare", args);
        if (preparation.error) throw new Error("server_unavailable");
        if (!preparation.data) {
          counts.cancelled++;
          finished = true;
          break;
        }
        const prepared = preparation.data as CleanupPreparation;
        if (!Array.isArray(prepared.objects)) {
          throw new Error("server_unavailable");
        }
        if (prepared.objects.length) {
          const bucket = prepared.objects[0].bucket;
          const names = prepared.objects.filter((item) =>
            item.bucket === bucket
          ).map((item) => item.name);
          const removed = await database.storage.from(bucket).remove(names);
          if (removed.error && String(removed.error.statusCode) !== "404") {
            await finish(false, "storage_unavailable");
            finished = true;
            break;
          }
          continue;
        }
        if (prepared.auth_user_id) {
          const removed = await database.auth.admin.deleteUser(
            prepared.auth_user_id,
          );
          if (removed.error && removed.error.status !== 404) {
            await finish(false, "auth_unavailable");
            finished = true;
            break;
          }
        }
        await finish(true);
        finished = true;
        break;
      }
      if (!finished) await finish(false, "cleanup_pending");
    } catch {
      // An unconfirmed external commit is retried under the same immutable target.
      // The lease expires if even the retry acknowledgement cannot be stored.
      try {
        await finish(false, "server_unavailable");
      } catch {
        counts.failed++;
      }
    }
  }
  return counts;
}
