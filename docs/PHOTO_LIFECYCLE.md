# Photo upload lifecycle (#73)

Photos in the P07–P09 draft stay local until authentication. A member upload now
reserves a fresh immutable `profile UUID/64 hex.png` version through
`avatar_upload_begin` before Storage upload. The 64 hex version is random, not a
content hash. A failed upload/finalization retry owns a new version. Admin uses
`admin_avatar_upload_begin`: the same actor/operation/content retains its path;
a completed receipt skips upload entirely. An expired unfinished operation gets
a fresh path, without changing successful operation receipts.

The private journal protects new uploads for 24 hours. Current `avatar_path`
references are always protected. A managed create reservation is active during
its first 24 hours or while its upload protection lasts. Reservations themselves
are never deleted by this worker. The existing account/profile deletion queue
continues to own its entire target/abandoned prefixes and immediate deletion;
photo cleanup does not change that behavior or retain a photo archive.

Cleanup claims only tracked, unreferenced objects after protection expires.
Profile finalization, Storage writes and cleanup share path locks, following
profile/reservation → sorted path → journal row order. Claim uses try-locks and
never locks a profile after taking a path lock. Before external removal, prepare
rechecks references, object ID and the 90-second lease. `storage.remove` deletes
one exact path; SQL never deletes hosted Storage metadata. Transient failures use
bounded exponential backoff (up to one hour). Completion rechecks actual object
absence. Disabling cleanup prevents new claims and preparation; already issued deletions may
finish, so disabling is not a rollback of an external DELETE.

A claimed path stays retired permanently, even after lease expiry, failure or
completion. Upload/reference guards reject reuse. Minimal path tombstones are
necessary because a timed-out older HTTP DELETE can finish after a later claim;
a fresh upload must never occupy that same path. No image bytes are stored in
the journal. Unexpected object-ID/reference conflicts quarantine the job instead
of deleting the object.

## Reviewed activation by the coordinator

The migration defaults cleanup **OFF**. This task does not enable it, change cron,
delete hosted objects, or publish the frontend. The existing authenticated
maintenance endpoint calls the module; its private bearer is unchanged.

1. Review/apply the application migration while OFF, then deploy Admin and
   maintenance together with the new module. Publish the matching upload client.
   Old open tabs with the former deterministic uploader should reload before
   reusing a retired photograph. They fail safely rather than bypassing a fence.
2. Read `avatar_cleanup_inventory(p_limit := 100, p_after := null)` as service
   only. For subsequent pages pass the previous page's last `path`; max page200.
   Inventory has no side effects. Keep path/identity dumps out of public logs.
3. Unknown paths/owners and untracked historical objects are never claimed
   automatically. Review known legacy objects against existing profile/upload
   provenance and preserve acceptance data. Import only the exact reviewed list:
   `avatar_cleanup_adopt(p_objects := '[{"path":"<UUID>/<64hex>.png","object_id":"<UUID>"}]'::jsonb)`.
   Max100 entries per call, exact current ID required. A changed inventory fails
   atomically. References, account-deletion candidates and all unpublished legacy
   reservations are excluded. Repeated import is a no-op and never resets a
   tombstone. Adoption starts a NEW 24-hour grace; it does not delete anything.
4. Re-read inventory, inspect candidate categories and protected objects, then
   explicitly call `avatar_cleanup_set_enabled(true)` only after that review.
   No new cron is necessary. Inspect `maintenance.photos` counts and private job
   `last_error`/`next_attempt_at`. To prevent new claims, set enabled false.
5. Verify protected current photos, successful replacement and worker outcomes.
   A client-facing acceptance remains separate from these technical checks.

All inventory/import/claim/prepare/finish/allocation RPCs are service-only except
`avatar_upload_begin`, which derives the actor from authenticated JWT identity,
requires a live owned Auth session and permits only that actor's prefix (including
pre-membership registration). Client-supplied owner identities are not trusted.

## Local verification

Replay application migrations using `supabase/tests/bootstrap.sql` only in an
empty isolated Postgres stand-in (exclude the two Supabase scheduling migrations).
Run `avatar_cleanup.sql`, `avatar_cleanup_admin.sql`, plus the existing account
deletion, reservation cleanup and service-role regressions.

`python3 scripts/test_avatar_lifecycle.py <paul-container> <paul_photo73-database>`
runs real PostgreSQL transactions and unchanged production SDK/worker code against
a loopback HTTP/filesystem Storage stand-in. It verifies replacement, abandonment,
active upload, both finalize/cleanup race orders, lock ordering, expired lease
with late DELETE, and partial Storage failure/retry. It is not hosted Supabase
acceptance; it creates/removes only its own fixture in the named isolated DB.
