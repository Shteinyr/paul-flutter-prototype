# Mobile admission and native push rollout

This is a coordinated server/client transition on the approved Paul test project.
It is not a backward-compatible server-only upgrade for the published web v27.
Do not run the disposable SQL bootstrap or test fixtures on hosted Supabase.

## Local release gate

Run `python3 scripts/test_native_push.py` from the checkout. It creates one
named, disposable PostgreSQL container with no network, ports or volumes; loads
legacy history **before** applying the admission snapshot; then tests admission,
Storage policies, receipt recovery and native push. Its `finally` removes only
that container and verifies removal, including after a failure.

Run the actual handler tests for `invitations` (including
`profile_merge_test.ts` and `verified_google_test.ts`), `account`, `admin`, `chat`,
`community`, `native-push`, and `native-push-worker` (handler and transport).
These use local/mocked providers; they do not send messages or operate hosted
data. GitHub Actions is not part of this gate.

## Ordered cutover

Retain the current frontend and Edge versions and the approved database recovery
point before deployment. Coordinate a short interruption of **new sign-in and
registration**, including old requests already in flight. Existing eligible
member sessions and application records must not be deleted or reset.
This revision amends the not-yet-applied admission migration. If hosted history
already contains that version, use a reviewed follow-up ALTER migration instead
of rerunning this CREATE migration or editing recorded migration history.

1. Deploy **all seven** functions below from the same source revision, including
   each function's imports and pinned dependency configuration:

   | Function | Entry point | Boundary enforced |
   | --- | --- | --- |
   | `invitations` | `supabase/functions/invitations/index.ts` | Verified Auth session; admission for member actions; session-bound prepare/redeem |
   | `account` | `supabase/functions/account/index.ts` | Current session admission for profile/capabilities/new deletion; original deletion receipts remain usable |
   | `admin` | `supabase/functions/admin/index.ts` | Verified session admission before every admin action and the existing role/grant checks |
   | `chat` | `supabase/functions/chat/index.ts` | Verified session admission plus existing conversation permissions |
   | `community` | `supabase/functions/community/index.ts` | Verified session admission plus author/publication permissions |
   | `native-push` | `supabase/functions/native-push/index.ts` | `getUser`, captured session, service-only admitted binding RPCs |
   | `native-push-worker` | `supabase/functions/native-push-worker/index.ts` | Mandatory private Bearer secret; admission/generation/lease checks before delivery |

   The new prepare/redeem RPCs are intentionally unavailable before step 2, so
   registration returns `503 server_unavailable`. There is **no fallback** to
   legacy `redeem_registration_invitation`. Other member operations retain the
   existing SQL session check until the admission migration replaces it.

2. Apply the complete migrations in this order:

   - `20261115045020_invite_session_admission.sql`
   - `20261115063818_native_push_transport.sql`

   Apply each migration transactionally through migration tooling, not as
   selected individual statements. The compatibility snapshot runs exactly
   once. Never refill admissions from all current Auth sessions later to repair
   a `403`: that would admit fresh sessions without an invitation.

3. Publish/install the matching frontend, then resume new entry. Its protocol
   authorizes registration with `prepare` before `avatar_upload_begin`/upload,
   then finalizes with `redeem`. A new Auth session has no member network until
   a currently valid invitation admits it. Token refresh retains the same
   admitted session and does not consume another invitation.

Changing only the frontend or only the SQL is not a safe rollback strategy.
Keep the admission-aware Edge package installed while diagnosing failures;
do not reset users/history or restore broad legacy session exemptions.

## web v27 compatibility boundary

The published v27 first requests `network` and only then redeems its pending
invitation. The new server rejects that first request for an unadmitted Auth
session. v27 also uploads a registration photo without `prepare`. New entry
therefore requires the matching frontend/reload after cutover. Guest public
preview and already admitted active member sessions are separate from new entry.

The snapshot preserves active member sessions with a matching Auth user/profile
and no pending account deletion. Its immutable `legacy_snapshot_at` permits
acknowledgement only of this user's ordinary redemption or owner claim recorded
before that boundary. It does not run registration again, reconnect a removed
pair, change a profile/referral, or restore revoked owner rights. Unrelated
expired credentials, another user, new sessions and post-snapshot history cannot
use that compatibility path.

## Native push stays disabled until provider acceptance

Keep `PAUL_NATIVE_PUSH_ENABLED` unset/false during this server cutover. Neither
migration installs a cron job or activates FCM. Preserve the existing Web Push
worker/schedule and VAPID configuration.

`supabase/config.toml` explicitly sets `verify_jwt=false` for both new native
functions. This skips only the gateway check: `native-push` still requires a
verified non-anonymous Auth user and DB admission; the worker still requires
`PAUL_NATIVE_PUSH_WORKER_SECRET` with at least 32 characters. An ordinary user
JWT or a missing secret must not authorize the worker.

Actual activation separately requires the matching Firebase/APNs app setup,
FCM service account configuration and approved worker scheduling, followed by
physical-device delivery/tap acceptance. The transport uses FID in `message.fid`.

### Provider activation preflight

- Register Android/iOS apps for the exact test or approved delivery identifiers.
  Download their SDK configs through the official Firebase tools. Android must
  generate native resources from its matching `google-services.json`; Dart-only
  configuration does not establish terminated-process delivery. Both hosts must
  enable FID registration. iOS also needs its early UIScene notification delegate,
  background modes and a signed push entitlement matching the APNs setup.
- Use a dedicated sender service account in the target project. A custom role
  containing only `cloudmessaging.messages.create` is sufficient for sending;
  do not grant project Owner/Editor. Enable the FCM HTTP v1 API. The worker signs
  OAuth JWTs with its own account key and needs no Token Creator delegation.
- Set `PAUL_FCM_PROJECT_ID`, `PAUL_FCM_CLIENT_EMAIL`, `PAUL_FCM_PRIVATE_KEY` and
  an independent `PAUL_NATIVE_PUSH_WORKER_SECRET` of at least 32 characters only
  in the server environment. Keep `PAUL_NATIVE_PUSH_ENABLED=false` until the
  configured client and provider have been verified. APNs key/Key ID/Team ID
  belong in Firebase, never in Dart or Supabase client configuration.
- Keep the native worker schedule separate from the existing Web Push and
  maintenance jobs. Store its bearer in Vault and verify that unauthenticated
  calls still fail. Do not enable a schedule or announce delivery merely because
  the Firebase project exists or the app compiles.
- Use only designated QA recipients for actual provider delivery and tap checks.
  Cover both fixed notification types, foreground/background/ordinary terminated
  launch, and rejected navigation after logout or loss of access. Local provider
  mocks, synthetic notifications and a successful FCM response do not prove
  receipt or a real tap on a phone.

## Verified provider configuration · 16 November 2026

The existing Firebase project `e-minutia-514216-h2` now has test apps for Android
`app.paul.paul_demo` and iOS `app.paul.paulDemo`. Their matching native SDK files
are downloaded locally and ignored by Git. Both platform builds passed using
matching public Firebase Dart defines. The iOS Simulator build uses those defines;
its ignored plist is not part of Xcode Resources. A default build without provider
configuration remains a development build without established push readiness.
These test identifiers are not the client store identifiers.

The dedicated service account has one custom permission,
`cloudmessaging.messages.create`. FCM/Installations APIs are enabled. Its credential
successfully minted a provider access token; an intentional validation-only request
for an unregistered technical FID returned `NotRegistered`, not an authorization
error. This is credential validation, not device delivery.

All five native worker settings are installed in the existing Supabase project;
their digests were compared with the private setup values. Unauthorized worker
requests returned 401, provider-disabled requests returned 503, and a temporary
provider-enabled call read the empty queue and returned 200 with all counts zero.
The provider flag was then restored to false. No notification was delivered.

Apply `20261116040916_native_push_worker_scheduler.sql` to install the service-only
`native_push_configure_scheduler(text,boolean)` RPC. Applying it creates no job.
Call it only from a trusted server setup process, passing the worker bearer as a
bound RPC value and an explicit boolean. It stores the bearer in the separate
`paul_native_push_runtime` Vault record and configures only
`paul-native-push-worker`. The cron command reads Vault at execution; it contains
no bearer or provider private key. False keeps the job inactive; true activates
it. Repeated/concurrent configuration creates one canonical job and Vault entry.
Existing Web Push and maintenance jobs are preserved.

The current hosted native scheduler and provider are disabled pending device
acceptance. Before activating them, verify current queue/recipients, the matching
provider credentials and device builds. Both the server flag and scheduler must
be explicitly enabled for automatic delivery. Disabling both stops automatic
sending without deleting messages, bindings, delivery history or other jobs.

The configured iOS Simulator launches to Join; the unsigned build reports a
Firebase unregister Keychain warning (`SecItemCopyMatching -34018`). It does not
prove signed iPhone registration. APNs key/Team/signing, a real Android device,
and foreground/background/terminated receipt and tap remain unverified. Do not
mark #39/#40 or client acceptance complete on this configuration evidence.

Run `python3 scripts/test_native_push_scheduler.py` for the isolated scheduler
contract gate: service-only access, invalid input rollback, concurrent retries,
rotation/enable/disable, dependency failure and preservation of other workers.
Its disposable PostgreSQL container stubs pg_cron/pg_net and is removed afterward;
its requests are not real provider delivery.

## Post-cutover checks

- An existing active saved session still reads its profile and history; a new
  session without an invitation cannot access APIs, Storage, Realtime or push.
- A new valid invite admits exactly its Auth session; expiry during entry cannot
  finalize registration. Reentry preserves the profile and referral count.
- A revoked/expired/exhausted ordinary invite, inactive issuer, or
  revoked/expired/claimed/retargeted owner invite immediately invalidates its
  outstanding upload permit on the next Storage request. An admitted member's
  own photo access remains authorized by admission, not by this temporary permit.
- A real legacy lost-ACK retry only acknowledges proven pre-snapshot history;
  it cannot grant admission to another session or restore removed connections or
  owner permissions.
- Provider-disabled native worker makes no FCM calls. Validate unauthorized
  native API/worker rejection independently of Firebase credentials.
