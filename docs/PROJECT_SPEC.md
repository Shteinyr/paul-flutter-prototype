# Product scope and architecture

## Purpose

Digitise professional referrals in a community. The original brief described a New York community whose members found specialists and work through personal introductions.

Organisers need a structured directory and shared hiring requests. Members need to describe what they offer and seek, find relevant people, see mutual contacts and start a conversation. These are intended benefits, not measured commercial results.

## Screen groups

| Group | Capability |
| --- | --- |
| P01 | Profile photo, name, occupation and own Contacts card |
| P02 | Description and skills editor, persistence, validation and deletion |
| P03 | Profile viewing, See More and connection count |
| P04 | Invitation QR/link/code, 15-minute validity and refresh |
| P05 | Local contact selection and invitation sharing |
| P06 | Entry, onboarding, provider authentication and session admission |
| P07 | Offered skills, suggestions, free text and saved drafts |
| P08 | Optional sought skills with the same catalogue |
| P09 | About You, photo upload and cleanup lifecycle |
| P10 | Text chat, history, unread, drafts, retries and notifications |
| P11 | Managed profiles, switching, reply-as and administrator roles |
| P12 | Name/skill search and All / Offer / Hiring filters |
| P13 | Community Hiring, publication, closure and expiration |
| P14 | Mutual contacts without exposing another person's complete graph |
| P15 | Confirmations, permissions and invitation-level dialogs |
| P16 | Limited read-only browser preview and application handoff |

## Platforms

One Flutter/Dart codebase contains iOS/Android hosts and browser targets. The installed application is app; preview is the limited browser target; review is a full authenticated browser review; demo is the earlier offline prototype.

The portfolio uses that existing demo without changing production authentication. Its local profile and simulated conversations are separate from the real backend. Live Hiring and administrator operations remain in the full source; the offline prototype does not claim to reproduce them.

## Core rules

Navigation: Contacts → Hiring → Chat → Profile. New participants verify an invitation, fill offered skills, optional sought skills and About You, then use a configured authentication provider. Existing-member entry skips profile creation but still checks an invitation for a new session. Token refresh of an admitted session preserves access.

Completed personal invitations determine levels: below two invitees, one new external recipient per day; from two, unrestricted new conversations; from ten, expanded offering and Community publishing. Search and Hiring readership remain available at every level.

Hiring requests disappear after author closure or 30 days. Account deletion removes profile visibility and connections while retaining counterpart conversations under Deleted user. Phone verification/discovery, company tariffs, chat media and Hiring history were excluded or deferred.

## Architecture

Modules separate views, controllers and repositories/stores. Native adapters provide photos, contacts, sharing, links, notification integration and SQLite operation journals.

Supabase supplies PostgreSQL, Auth, private Storage, Realtime and Edge Functions. Ownership, membership and roles are checked on the server. Stable operation identifiers protect retries. Profile merges protect concurrent changes. Maintenance completes deletion and expiration.

Browser push uses service workers and VAPID. Native messaging integrates Firebase with separate Android and Apple signing/APNs delivery requirements. Private keys belong only in server configuration.

## Validation and delivery boundaries

Flutter tests, analysis, packaging, isolated SQL/Edge checks and web/iOS Simulator/Android builds provide engineering evidence. A build is not a store release, a simulated callback is not real OAuth and a sharing sheet is not proof of delivery.

Physical-device provider login, permissions, native push delivery/tap and store signing remain separate criteria. Browser cold-start variability is documented in the backlog. Original issues/PRs/commits retain historical evidence; older records may be in Russian.

See [development](../CONTRIBUTING.md), [backlog](BACKLOG.md), [rollout](MOBILE_BACKEND_ROLLOUT.md) and [photo lifecycle](PHOTO_LIFECYCLE.md).
