# Product backlog and integration boundaries

The working platform is the Flutter application in the browser. Supabase and the browser hosting are configured. The sequence below retains implementation and client-acceptance boundaries. The first Figma column contains P01–P13 and the client's preliminary 60-hour estimate. Confirm acceptance criteria, available accounts, per-item estimates and delivery dates before starting each stage. Proposed M1/M2/M3 milestones and technical sub-issues are marked draft.

## Decisions for the 10-minute call

1. Agreed browser/device matrix, notification permission and system-tap acceptance.
2. Exact profile fields, searchable fields, filter combinations and sort order.
3. Connection rule: one message from each side, QR scan, invite code, and any approval or blocking rules.
4. Contacts matching: what data may leave the device, what happens on denied permission, and how invitation delivery should work.
5. Chat scope: text only, delivery/read state, reconnect behaviour and push notification behaviour.
6. Account ownership, access and what counts as acceptance within the time budget.

## Proposed sequence

| Stage | Work | Acceptance example |
| --- | --- | --- |
| 1. Repository and environments | Owner-controlled private repository, CI, separate development/production configuration and access roles | A clean clone passes checks and builds; no service secrets are in source |
| 2. Authentication | Google and Apple sign-in, persistent session, logout and account deletion | A real user signs in on the agreed devices; another user's account cannot be accessed |
| 3. Profiles and photos | Server-backed profile and photo storage; field validation and access rules | Edits appear after signing in on a second device; unauthorised edits are rejected |
| 4. Discovery | Search, filters, sorting and pagination for the agreed fields | Specified combinations return expected results, including empty and paged states |
| 5. Messaging and connections | Persisted conversations, realtime delivery, unread state and idempotent connection creation | Two real accounts exchange messages and connect exactly once; history survives a reconnect |
| 6. Browser Push | Web Push subscriptions, server outbox worker, generic notifications and authorized routing | Actual Chrome deliveries passed, system tap and final device acceptance remain open |
| 7. Invites and contacts | Server-issued invitation tokens with expiry/revocation; deep links; consent-based contact matching | A valid invite connects once; expired or revoked invites fail; denied permission has a usable fallback |
| 8. Delivery | Browser QA, error recovery, identified web build and handover | Owner opens the agreed URL and reproduces accepted scenarios |

The live implementation includes guest preview, invitations, onboarding, profiles, text chat, administration, scoped skill search and browser Web Push. Open product decisions and acceptance are tracked per block in PROJECT_SPEC and GitHub. Community requests remain unimplemented.

## Current backend

Flutter in the browser uses the separate Paul Supabase project for PostgreSQL, Auth, Storage, Realtime and Edge Functions. Browser Web Push uses VAPID and the existing server outbox, with server-generated keys in Supabase Vault. Native distribution and native push belong to a later phase.

Keep profile and chat storage behind the existing store interfaces. Authenticated user IDs, membership checks, migrations and row-level policies are implemented. Multi-user history lives on the server, local preferences retain drafts and cache state. Contact matching and invite acceptance belong on authenticated server endpoints.

## Owner-controlled services needed for real integrations

- GitHub repository/organisation and developer access.
- Transfer of the existing Supabase project and service ownership to the agreed client account.
- Google/Apple web OAuth configuration, provider consents and developer access.
- Agreed real browsers/devices and operating-system notification acceptance.
- Client-owned browser domains when required for provider configuration.

Share access through service roles/invitations. Keep signing credentials and service secrets outside the repository.

## Documentation references

- [Supabase Flutter SDK](https://github.com/supabase/supabase-flutter/tree/main/packages/supabase_flutter)
- [Supabase Realtime](https://supabase.com/docs/guides/realtime)
- [Scheduled Edge Functions](https://supabase.com/docs/guides/functions/schedule-functions)
