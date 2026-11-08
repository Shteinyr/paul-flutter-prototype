# Production backlog — proposal for the kickoff call

This is a proposed implementation sequence, not a commitment that the entire advertised scope fits 100 hours. Confirm the acceptance criteria, available accounts and per-item estimates with the owner before agreeing the two-week / 100-hour scope.

## Decisions for the 10-minute call

1. First delivery platforms: iOS, Android, or both; required installation/distribution method.
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
| 6. Push | Device tokens, FCM/APNs configuration, notification routing and permission handling | A real device receives a background notification and opens the correct conversation |
| 7. Invites and contacts | Server-issued invitation tokens with expiry/revocation; deep links; consent-based contact matching | A valid invite connects once; expired or revoked invites fail; denied permission has a usable fallback |
| 8. Delivery | Device QA, error recovery, agreed distribution build and handover notes | Owner can install, reproduce the agreed acceptance paths and operate the project |

The existing prototype provides the UI review paths and local state/persistence patterns. The server-backed stages above remain production work.

## Proposed backend

Flutter + Supabase (PostgreSQL, Auth, Storage, Realtime and Edge Functions), with Firebase Cloud Messaging / APNs for native push. This is a proposal; no Supabase or Firebase project is configured in this prototype.

Keep profile and chat storage behind the existing store interfaces. Introduce authenticated user IDs, membership checks, database migrations and row-level access policies when implementing the backend. Local preferences remain a cache/draft store, not the source of truth for multi-user data. Contact matching and invite acceptance belong on authenticated server endpoints.

## Owner-controlled services needed for real integrations

- GitHub repository/organisation and developer access.
- Supabase project and chosen hosting region/budget.
- Google OAuth configuration, Apple Developer identifiers and signing/distribution access.
- Firebase project, APNs credentials and agreed test devices.
- A verified app/universal-link domain if deep-link acceptance is included.

Share access through service roles/invitations. Keep signing credentials and service secrets outside the repository.

## Documentation references

- [Supabase Flutter SDK](https://github.com/supabase/supabase-flutter/tree/main/packages/supabase_flutter)
- [Supabase Realtime](https://supabase.com/docs/guides/realtime)
- [FCM for Flutter](https://firebase.google.com/docs/cloud-messaging/flutter/get-started)
