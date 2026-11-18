# Product backlog and integration boundaries

The working platform is the Flutter application in the browser. Supabase and the browser hosting are configured. The sequence below retains implementation and client-acceptance boundaries. The first Figma column contains P01–P13 and the client's preliminary 60-hour estimate. Record agreed acceptance criteria, account dependencies, estimates and delivery dates when they are confirmed. Proposed M1/M2/M3 milestones and technical sub-issues are marked draft.

## Rejected v18 correction

Alexander rejected v18 on 11 November 2026. Epic #94 and issues #95–#102 cover the audited corrections. Contacts → Hiring → Chat → Profile is the agreed navigation; Hiring is the second tab. Search uses a compact dropdown over Contacts, portrait/name/matched-skill rows and All / Offer / Hiring. Onboarding retains the local draft/photo and originating step when returning from Join, including after reload. Admin retains the selected profile context and portraits. Remove unapproved Preview labels and visible technical QA text. Historical checks do not establish client acceptance; publish only the independently checked combined result. Real Google/Apple and physical notification acceptance remain separate.

## Accepted MVP decisions, 11 November 2026

The interface follows the existing mobile Figma screens in Flutter for the browser. Alexander authorised implementation of the following decisions.

1. Search covers all registered members, including managed profiles. Shared skill suggestions retain free-text entry in profile, onboarding and search.
2. Invitation levels count completed registrations through a personal invitation. Below two invitees, one new external recipient per day. From two, unrestricted messaging. From ten, expanded offering skills and Community publishing. Search and Hiring readership are available at every level.
3. Community requests are visible to all registered members. Authors can have any number of active requests. Closing a request or reaching30days deletes its record. Push targets registered members with current notification consent.
4. Confirmed account/profile deletion immediately removes photo, description, skills and connections. Counterpart conversation history uses the label Deleted user.
5. Updated12November: P05 only invites a friend through copying, system sharing or the user's SMS app, with local contact selection where supported. Own-phone linking, SMS verification, discovery consent and phone matching (#70) are excluded. No external SMS provider is required. Actual phone sharing and client acceptance remain #34/#35/#41.
6. Company tariffs/limits and optional request statistics remain future tasks #84/#85. Closed and expired Hiring requests are hidden from everyone; do not add a history screen. Real Google/Apple integration is verified against actual owner configuration and service results.

Implementation issues are #43/#45/#46/#47/#48/#72/#76/#86. #70 is cancelled following the scope change, not accepted as completed. Existing local checks and client acceptance are recorded separately.

## Proposed sequence

| Stage | Work | Acceptance example |
| --- | --- | --- |
| 1. Repository and environments | Owner-controlled private repository, CI, separate development/production configuration and access roles | A clean clone passes checks and builds; no service secrets are in source |
| 2. Authentication | Google and Apple sign-in, persistent session, logout and account deletion | A real user signs in on the agreed devices; another user's account cannot be accessed |
| 3. Profiles and photos | Server-backed profile and photo storage; field validation and access rules | Edits appear after signing in on a second device; unauthorised edits are rejected |
| 4. Discovery | Search, filters, sorting and pagination for the agreed fields | Specified combinations return expected results, including empty and paged states |
| 5. Messaging and connections | Persisted conversations, realtime delivery, unread state and idempotent connection creation | Two real accounts exchange messages and connect exactly once; history survives a reconnect |
| 6. Browser Push | Web Push subscriptions, server outbox worker, fixed Message/Hiring type labels and authorized routing | Actual Chrome deliveries passed, system tap and final device acceptance remain open |
| 7. Invites and contacts | Server-issued invitation tokens with expiry/revocation; invitation links, copying, system sharing and optional local contact selection | The current invitation reaches the user's chosen sharing app; cancellation or denied contact permission retains the manual path; expired or revoked invites fail |
| 8. Delivery | Browser QA, error recovery, identified web build and handover | Owner opens the agreed URL and reproduces accepted scenarios |

The live implementation includes guest preview, invitations, onboarding, profiles, text chat, managed-profile administration, global registered-member search, shared ESCO suggestions with free text, invitation levels, Community and browser Web Push. Account and managed-profile deletion retain counterpart histories. The obsolete phone-discovery entry is removed from the application; historical backend data and migrations are preserved. Technical results and client acceptance are tracked per block in PROJECT_SPEC and GitHub.

## Current backend

Flutter in the browser uses the separate Paul Supabase project for PostgreSQL, Auth, Storage, Realtime and Edge Functions. Browser Web Push uses VAPID and the existing server outbox, with server-generated keys in Supabase Vault. A separate maintenance worker expires Community requests and completes deletion cleanup independently of push availability.

Keep profile and chat storage behind the existing store interfaces. Authenticated user IDs, membership checks, migrations and row-level policies are implemented. Multi-user history lives on the server, local preferences retain drafts and cache state. Invite acceptance belongs on authenticated server endpoints. Selected invitation contacts stay local and are not matched against server phone numbers.

## Owner-controlled services needed for real integrations

- GitHub repository/organisation and developer access.
- Transfer of the existing Supabase project and service ownership to the agreed client account.
- Google/Apple web OAuth configuration, provider consents and developer access.
- Actual operating-system notification acceptance for the mobile Figma scenarios.
- Client-owned browser domains when required for provider configuration.

Share access through service roles/invitations. Keep signing credentials and service secrets outside the repository.

## Documentation references

- [Supabase Flutter SDK](https://github.com/supabase/supabase-flutter/tree/main/packages/supabase_flutter)
- [Supabase Realtime](https://supabase.com/docs/guides/realtime)
- [Scheduled Edge Functions](https://supabase.com/docs/guides/functions/schedule-functions)
