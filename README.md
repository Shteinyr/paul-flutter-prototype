# Paul Project

Flutter-приложение для профессиональных связей и поиска специалистов. Основа требований — макеты и комментарии Paul Galda в Figma.

## Документация

- [Карта требований: 16 блоков Figma](docs/PROJECT_SPEC.md) — экраны, сценарии, текущие статусы, приёмка и открытые решения.
- [Backlog](docs/BACKLOG.md) — общий перечень работ.
- [Порядок разработки](CONTRIBUTING.md) — задачи, ветки, commits, PR, проверки и релизы.
- [Исходные макеты](https://www.figma.com/design/8tCP0Pg2UghSOPP5bIg9Ra/UI?node-id=2034-3242).

## Задачи по блокам

| Блок | GitHub issue |
| --- | --- |
| [P01] Profile creation — Test | [#2](https://github.com/Shteinyr/paul-flutter-prototype/issues/2) |
| [P02] Profile creation — Next | [#3](https://github.com/Shteinyr/paul-flutter-prototype/issues/3) |
| [P03] Profile view → GitHub setup | [#4](https://github.com/Shteinyr/paul-flutter-prototype/issues/4) |
| [P04] QR code generation → Cloud setup | [#5](https://github.com/Shteinyr/paul-flutter-prototype/issues/5) |
| [P05] Contact access | [#6](https://github.com/Shteinyr/paul-flutter-prototype/issues/6) |
| [P06] Registration / Splash screen → Firebase | [#7](https://github.com/Shteinyr/paul-flutter-prototype/issues/7) |
| [P07] Getting Started — offered skills 1/3 | [#8](https://github.com/Shteinyr/paul-flutter-prototype/issues/8) |
| [P08] Searching Skills — 2/3 | [#9](https://github.com/Shteinyr/paul-flutter-prototype/issues/9) |
| [P09] About You — 3/3 | [#10](https://github.com/Shteinyr/paul-flutter-prototype/issues/10) |
| [P10] Chat — Push → Firebase / WebSocket setup | [#11](https://github.com/Shteinyr/paul-flutter-prototype/issues/11) |
| [P11] Admin + User management | [#12](https://github.com/Shteinyr/paul-flutter-prototype/issues/12) |
| [P12] Skill search + Filter | [#13](https://github.com/Shteinyr/paul-flutter-prototype/issues/13) |
| [P13] Community reach out — Local | [#14](https://github.com/Shteinyr/paul-flutter-prototype/issues/14) |
| [P14] Connections — Search — Hiring — Chat | [#15](https://github.com/Shteinyr/paul-flutter-prototype/issues/15) |
| [P15] Pop-ups | [#16](https://github.com/Shteinyr/paul-flutter-prototype/issues/16) |
| [P16] Web view — Prompts / Guest → Profile — React Online | [#17](https://github.com/Shteinyr/paul-flutter-prototype/issues/17) |

## Текущая база

Локальный Flutter-прототип покрывает Profile → Contacts, публичные профили, навыки, локальный chat и демонстрации QR/Connect/уведомлений. Live-версия включает гостевой просмотр, контекстный вход, серверные приглашения, браузерные Clipboard/Share/Contact Picker, профили, связи, личную текстовую переписку и поиск навыков среди собственного профиля и прямых контактов. Техническая приёмка поиска и её границы зафиксированы в [P12](docs/PROJECT_SPEC.md#p12). Настройка Google/Apple, background push и аппаратная проверка системных диалогов имеют отдельные критерии.

В репозитории находятся исходники Flutter, документация, задачи, шаблоны и workflow GitHub Actions. Для принятой версии поиска `5db83ad` прошли 132 Flutter VM tests, 6 Chrome tests, 2 packaging checks, 14 Deno tests, анализ без замечаний, форматирование и demo/live release web builds. Hosted Actions запускаются по отдельному разрешению.

## Порядок работы

Issue → согласованные критерии и оценка → отдельная ветка → PR → проверки → приёмка. Статусы: Todo → Ready → In progress → Review → Awaiting acceptance → Accepted. Первая очередь охватывает P01–P13. Предварительные M1/M2/M3 и их подзадачи отмечены draft. Клиентский ориентир 60 часов требует оценки по конкретным критериям. Сроки пока не утверждены.

Репозиторий private. Проверочный backend расположен в отдельной организации Paul на Supabase Free.

## Run locally

Validated SDK: **Flutter 3.47.9 / Dart 3.13.7**. Dependencies are recorded in `pubspec.lock`.

```sh
flutter pub get --enforce-lockfile
flutter run -d chrome
```

For a browser-independent development server:

```sh
flutter run -d web-server --web-hostname 0.0.0.0 --web-port 8080
```

The default demo uses local data. The live configuration connects to the Paul Supabase project as described below.

## Checks and build

```sh
dart format --output=none --set-exit-if-changed lib test
flutter analyze --no-pub --fatal-infos
flutter test --no-pub --coverage
bash scripts/build_demo.sh
```

The build script produces the browser app in `dist/`. To review the release build locally, serve `dist/` with a local static server.

For an explicit source handoff, run `bash scripts/build_demo.sh --include-source`. The separate archive is written to `build/paul-demo-source.zip`. It includes only tracked application paths. Project documents and local scratch files are excluded. Publish only `dist/` for a browser preview.

Packaging regression checks run with `python3 -m unittest discover -s scripts -p 'test_*.py' -v`.

The GitHub Actions workflow defines formatting, analysis, tests and a release web build. **Flutter checks is disabled as of 2026-11-09.** A hosted run requires Alexander's explicit approval naming this repository and workflow. Local checks remain available. When enabled for an authorized run, browser and coverage artifacts are retained for seven days. Record checks against the exact commit.

## Code map

| Path | Responsibility |
| --- | --- |
| `lib/app.dart` | Navigation, editing forms, contacts and reusable profile/avatar widgets |
| `lib/profile/` | Profile model, persistence interface, controller, sample migration and public views |
| `lib/chat/` | Local chat state/store, connection rules, simulated replies and conversation UI |
| `lib/demo_connect.dart` | Demonstration QR / Connect / invite flow |
| `lib/live/` | Supabase integration, protected contacts, registration host and rotating live QR |
| `lib/search/` | RLS-scoped skill suggestions, All/Offering/Hiring, pagination and search state |
| `lib/onboarding/` | P07–P09 steps and durable drafts |
| `supabase/` | Migrations, invitation function and SQL regression |
| `lib/demo_contacts.dart` | Fictional contact content |
| `lib/photo_picker.dart` | Photo selection, validation and image normalisation |
| `test/` | Interaction, persistence, connection, notification and failure-recovery tests |
| `assets/` | App icons, sample portraits and bundled Noto Sans font with its OFL notice |
| `.github/workflows/flutter-ci.yml` | Automated repository checks and build |

## Persistence

- Profile key: `paul.demo.profile.v1`; payload schema version 2 retains compatibility with version 1.
- Chat key: `paul.demo.chat.v1`; stores local messages, drafts, unread state, connections and the demo-notification choice.
- Writes are serialised so an older save cannot overwrite a later edit or profile deletion. Errors expose retry actions.
- The initial own profile is Paul Galda / Business Analyst. An untouched older Julia sample is migrated; existing user edits are preserved.
- An explicitly deleted profile remains empty after a restart. Fictional sample contacts remain available.
- Data does not sync across devices or browser origins. Invite preparation is session-only.

## Live invitations and registration

The web integration uses **supabase_flutter 2.18.3**, Supabase Auth, Postgres, private avatar Storage and the `invitations` Edge function. Apply the SQL files in `supabase/migrations/` in order. Their versions match the verified hosted migration history. The function validates the user through Supabase Auth and alone can execute its service-role RPCs.

Build with a local JSON configuration containing `PAUL_LIVE`, `SUPABASE_URL`, `SUPABASE_PUBLISHABLE_KEY` and `PAUL_APP_URL`. The URL must be the actual browser origin. Only the publishable key belongs in this configuration.

```sh
bash scripts/build_live.sh --dart-define-from-file=/absolute/path/to/live.json
```

The script produces `dist/` from an isolated build with its own asset manifest. The guest preview bundles the provided Paul and Julia portraits. Member portraits load from private Storage.

Invitations last exactly 15 minutes. An open QR screen automatically replaces expired QR and numeric code. Multiple users can redeem within that lifetime. Reissuing the same token retains the original deadline. The server checks expiry again after Auth, activates membership/profile and creates a unique connection atomically. First-owner bootstrap is a controlled one-use server invitation with no issuer. Keep its raw credential in a private local file.

Supabase persists the main browser session across reopening. Pending invitation, profile snapshot and OAuth-finalization marker use sessionStorage. Logout clears the live pending state and onboarding draft. The current preview uses the SDK's JavaScript-readable browser storage.

Google/Apple provider setup and their real OAuth acceptance remain pending. Client Terms/Privacy URLs and server account deletion remain open P06 criteria. Test fixture password sessions are confined to verification.

Focused local checks include `test/invitation_controller_test.dart`, `test/live_app_auth_test.dart` and `supabase/tests/invitations.sql`. `scripts/test_live_invitations.py` runs against explicitly prepared disposable QA identities supplied through a private fixture. Its basic phase requires fresh inactive invitees. Keep fixture contents, tokens and invitation links out of command output and commits.

## Browser Web Push server

The `push` Edge Function provides public `config` discovery and authenticated `subscribe`, `status`, `unsubscribe` and `resolve` actions. The server verifies Auth identity, the JWT session against `auth.sessions`, active membership and current per-conversation permissions. Managed recipients resolve to current operators with an active role and `can_reply` grant. Each browser binding belongs to one Auth user and session. Repeated registration preserves its canonical ID and original history cutoff.

Push payloads contain `version: 1`, `delivery_id`, `binding_id` and `recipient_user_id`. The service worker displays fixed generic text, checks its current local binding and resolves the route through the server on click. The original message text and profile details stay in the authorized chat API.

Private server configuration uses `PAUL_PUSH_ENABLED`, `PAUL_VAPID_PUBLIC_KEY`, `PAUL_VAPID_PRIVATE_KEY`, `PAUL_VAPID_SUBJECT`, `PAUL_PUSH_ALLOWED_ORIGINS` and `PAUL_PUSH_WORKER_SECRET`. Only the public VAPID key appears in discovery. A disabled or incomplete configuration returns `enabled: false`. Store secret values outside Git and pass them through the platform secret manager. Both functions use application-level authorization and require deployment with gateway JWT verification disabled.

`push-worker` requires the private worker bearer. A request processes at most four claims, two concurrently, with five-second SQL HTTP and provider timeouts. The initial lease is 60 seconds. A fresh authorization preflight fences each claim, renews its lease to 30 seconds and supplies a conservative remaining-time budget. Stale or expired fences cannot disclose endpoints or complete work. Failed transient deliveries retry up to five attempts with bounded backoff. HTTP 404/410 disables the exact binding. Endpoints use the explicit HTTPS FCM/Mozilla/Apple allowlist, with redirects disabled.

Notification delivery expires 24 hours after its outbox event, and the final 30 seconds are excluded from dispatch. Provider TTL is 300 seconds. The browser deduplication ledger retains IDs for 26 hours, with an 8192-entry fail-closed cap and age-based pruning. Messages, outbox rows and audit remain stored. Unknown network commits reuse the delivery ID and provider topic. Client-side deduplication covers repeated delivery, while fresh binding and click authorization guard queued notifications across logout or permission changes.

After reviewed migrations and functions are deployed, provision Vault names `paul_push_worker_url` and `paul_push_worker_secret` privately. The latter matches the Edge worker secret. The reviewed `supabase/ops/schedule_web_push.sql` schedules the existing project worker every minute through `pg_cron` and `pg_net`. It replaces only the job named `paul-web-push-worker`. Disable that exact cron job and the enabled flag to stop delivery.

Local checks use `supabase/tests/web_push.sql`, `scripts/test_push_concurrency.py`, and `supabase/functions/push/handler_test.ts`. The concurrency script accepts only isolated Paul push database names. Deno dependency locks pin the push library and transitive dependencies. Real background browser delivery has a separate joint acceptance gate.

## Live text chat

The `chat` Edge function verifies every bearer with Auth and calls service-only RPCs. Apply the chat migrations in order, then deploy `supabase/functions/chat/index.ts` together with `handler.ts`. Participants alone can read persistent conversations, roster and messages. A conversation starts with a direct contact. Self-chat is rejected. Message text supports 2000 grapheme clusters within 64 KiB of UTF-8, preserves its original payload and excludes NUL or blank-only input.

Realtime Settings must have Allow public access disabled. The Paul project is configured this way. `test_live_chat_realtime.ts` accepts `--require-private-only` after the two fixture paths to verify that authenticated public-mode and anonymous default-mode subscriptions are both rejected while authorized private signals still work.

`lib/live/chat_api.dart` exposes list/open/history/send/read/disconnect. History uses strict sequence cursors and bounded pages. Repeating an author/conversation/client-message ID returns the same message. Changing its text conflicts. A private notification event is stored in the same transaction as each new message. Deleting a connection retains the existing dialogue. Reconnecting requires fresh messages from both participants after removal. Repeated removal uses its original operation ID, and cannot delete a connection recreated since that operation.

`LiveChatController` persists the operation ID, exact text and account-scoped drafts in the current tab’s sessionStorage before sending. A failed acknowledgement remains retryable across reload of that tab. Different tabs keep independent journals. A new tab that copies its opener’s session state safely retries the same operation ID. Private Realtime inboxes send metadata-only invalidations, and the client fetches authorized history again on subscription/reconnect. The membership host calls pause/resume with visibility, closes the active conversation on departure and disposes the controller on account replacement. Pending text becomes sent only after server acknowledgement or recovery of the persisted message.

The isolated SQL gates are `supabase/tests/chat.sql` and `chat_realtime.sql`. `bootstrap.sql` is a minimal stand-in for an empty local Postgres container and must stay local. `scripts/test_chat_concurrency.py` accepts its explicit container name. Live HTTP and Realtime runners require public configuration and a private, explicitly assigned disposable QA fixture. The browser UI is integrated and under acceptance. Its two-account HTTPS gate passed history, unread/read, lost acknowledgement, manual same-UUID retry, independent tab journals/drafts, connection removal/restoration and cross-tab logout with zero page errors. Browser background push delivery has separate acceptance criteria. The outbox records events for that later delivery integration.

## Next production stage

See the [MVP backlog](docs/MVP_BACKLOG.md) for the remaining acceptance criteria and integration dependencies.

## Design reference

[Supplied Figma file](https://www.figma.com/design/8tCP0Pg2UghSOPP5bIg9Ra/UI?node-id=2034-3242). Implemented flows include profile creation/editing, public profile/skill views, local chat and the demonstration QR / Contact access stage.
