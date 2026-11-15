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

С 15.11.2026 основной продукт — устанавливаемое приложение **iOS/Android**. Общие Flutter-код и Supabase сохранены. `PAUL_TARGET=app` запускает основной первый вход по инвайту; `preview` предназначен для ограниченного P16; `review` — для полной проверки участника/Admin; `demo` явно включает прежнюю локальную демонстрацию. Готовность веб-версии и прежние принятые P01–P03/P12 сохраняются, но мобильная приёмка ведётся отдельно.

Новая очередь: #20 мобильные хосты/запуск; #142 SQLite-журналы; #143 допуск каждой новой Auth-сессии; #144 профиль/P15; #23/#24 Google и Apple на обеих платформах; #33–#35 ссылки/приглашения; #39/#40 native push; #31/#41/#49 мобильные проверки. Тестовая доставка: #145 TestFlight, #146 Google Play testing, #147 магазинный выпуск. Клиентские identifiers/signing и реальные Firebase/APNs/Apple credentials — зависимости внешней доставки, не основание выдавать локальные проверки за магазинную готовность.

Мобильная реализация объединена в [PR #148](https://github.com/Shteinyr/paul-flutter-prototype/pull/148), проверенный код — main e2a2161. Сервер обновлён; временная проверочная ссылка опубликована как Sites v29. Прошли 570 Flutter tests, 64 Deno tests, SQL gates, анализ/форматирование, две проверки упаковки и сборки iOS Simulator/Android Debug. В настоящем iOS Simulator проверены первый запуск/анкета и восстановление, Contacts, профиль/Admin, поиск, диалог/история, Hiring и системное Share-окно. Авторизованный проход использовал QA callback, а не Google/Apple; Android APK ещё не запускался на устройстве.

Остаются реальные Google/Apple, фото/контакты и передача приглашений на двух телефонах, Firebase/FCM/APNs и получение/нажатие push, клиентские домен/identifiers/signing, утверждённые Terms/Privacy и тестовая магазинная доставка. Нестабильный первый запуск браузерной версии остаётся в #102; мобильный запуск не зависит от загрузки браузерного движка. Приёмочная v18 была отклонена 11.11.2026; исправления [#94](https://github.com/Shteinyr/paul-flutter-prototype/issues/94) опубликованы последующими версиями, но публикация и технические проверки не означают клиентскую приёмку.

Порядок верхних вкладок по Figma и встрече: **Contacts → Hiring → Chat → Profile**. Hiring открывает общую ленту; отдельная кнопка Network hiring в Contacts удаляется. Подсказки раскрываются небольшим списком поверх Contacts, результаты показывают фотографии, имена и совпавшие навыки с фильтрами All / Offer / Hiring. Profile гостя открывает локальные P07–P09 до входа; возврат из Join сохраняет исходный шаг, текст и фото.

Live-версия Flutter в браузере включает гостевой просмотр, контекстный вход, приглашения, профили, связи, текстовую переписку, глобальный поиск зарегистрированных участников и Admin с переключением управляемых профилей. Общий English ESCO-справочник сохраняет свободный ввод. Уровни 2/10 зависят от завершённых личных приглашений. До двух приглашённых разрешён один новый внешний собеседник в день с обновлением квоты в 00:00 UTC, с двух — свободная переписка, с десяти — расширенные offering skills и публикация Community.

Community включает общую Hiring-ленту, публикацию, закрытие, удаление через 30 дней и браузерные Web Push согласившимся участникам. Подтверждённое удаление обычного или управляемого профиля скрывает его данные сразу и завершает очистку Storage/Auth через устойчивую серверную очередь. Очередь сохраняет префиксы фото незавершённого создания управляемых профилей, а сервер блокирует их позднюю загрузку после удаления создателя. Переписка собеседника сохраняется с подписью Deleted user. P05 передаёт приглашение другу через копирование, системную отправку или SMS-приложение пользователя; выбор контакта доступен при поддержке браузера.

Прежняя браузерная интеграция прошла 20 application migrations, 17 SQL suites, 68 Deno tests и 45 concurrency gates на изолированных базах. Её клиентские доказательства включают 249 VM tests, 6 Chrome tests, две проверки упаковки, анализ, форматирование и demo/live builds. Реальные доставки Web Push в Chrome проверены для чата и Community. Эти исторические результаты сохраняются отдельно от текущих мобильных проверок выше. Прежние Web Push/maintenance cron сохранены; native Firebase provider и cron не активированы. Системное нажатие и матрица устройств имеют отдельную приёмку. SMS-подтверждение исключено из объёма12.11.2026. Клиентская приёмка ведётся в GitHub по конкретной версии. Hosted Actions запускаются по отдельному разрешению.

## Согласованная очередь MVP от 11.11.2026

Рабочий интерфейс следует существующим мобильным экранам Figma во Flutter в браузере. В разработку переданы принятые изменения.

- Общий справочник навыков с подсказками и свободным вводом в профиле, onboarding и поиске. Поиск среди всех зарегистрированных участников, включая управляемые профили, ведётся в #45/#46/#76.
- Уровни по завершённым личным приглашениям2/10 и квота одного нового внешнего собеседника в день до двух приглашённых ведутся в #86. Чтение поиска и Hiring доступно на всех уровнях, публикация Community открывается на десяти.
- Admin с выбором управляемого профиля и окончательное удаление #43/#72. После подтверждения данные профиля удаляются сразу, у собеседника сохраняется переписка с подписью «Удалённый пользователь».
- Community/Hiring #47/#48 с общей лентой, свободным количеством запросов, удалением при закрытии автором или истечении30дней и Web Push участникам с действующим разрешением.
- Решение12.11.2026 заменяет прежнее согласование #70: привязка своего телефона, SMS-подтверждение, обнаружение и сопоставление номеров исключены. Остаётся передача приглашения другу. Существующие серверные данные и миграции сохраняются.

Результаты этой очереди проходят техническую проверку и клиентскую приёмку по связанным задачам. Реальный вход Google/Apple проверяется после настройки владельцем. Запрашивать SMS-провайдера для P05 не нужно. Тарифы компаний #84 и возможная статистика #85 остаются последующими доработками. Закрытые и истёкшие Hiring никому не показываются; экрана истории нет.

## Порядок работы

Issue → согласованные критерии и оценка → отдельная ветка → PR → проверки → приёмка. Статусы: Todo → Ready → In progress → Review → Awaiting acceptance → Accepted. Первая очередь охватывает P01–P13. Предварительные M1/M2/M3 и их подзадачи отмечены draft. Клиентский ориентир 60 часов требует оценки по конкретным критериям. Сроки пока не утверждены.

Репозиторий private. Проверочный backend расположен в отдельной организации Paul на Supabase Free.

## Run locally

Validated SDK: **Flutter 3.47.9 / Dart 3.13.7**. Dependencies are recorded in `pubspec.lock`.

```sh
flutter pub get --enforce-lockfile
flutter run -d <ios-or-android-device>
```

For a browser-independent development server:

```sh
flutter run --dart-define=PAUL_TARGET=review -d web-server --web-hostname 0.0.0.0 --web-port 8080
```

The default entry is the primary app, backed by the existing Paul project using public settings in `lib/config/app_configuration.dart`. Server/provider secrets are never client settings. Override public settings with `--dart-define-from-file` only when targeting another explicitly configured environment.

For browser review: `flutter run -d chrome --dart-define=PAUL_TARGET=review`.
For the explicit local demo: `flutter run -d chrome --dart-define=PAUL_TARGET=demo`.

### Installed app and separate browser targets

`bash scripts/build_mobile.sh ios-simulator` builds the main app for an installed
iOS Simulator. `ios-unsigned` prepares an unsigned iOS release; `android-debug`
builds an APK; `android-bundle` requires the client's release signing configuration.
The development identifiers are `app.paul.paulDemo` (iOS) and
`app.paul.paul_demo` (Android). They must be replaced with the client's identifiers
before store delivery. Neither a successful build nor a browser review confirms
TestFlight, Google Play or physical-device acceptance.

The pinned iOS dependencies use CocoaPods (`pod install`, with `Podfile.lock`)
and require iOS 15+. Swift Package Manager is disabled for this project.
Android uses Java 17+ (verified tooling: Java 21), compile API 37, minimum API 24,
AGP 9.1.1 and the NDK version pinned by Flutter. Only one SDK installation is needed.
The pinned plugins also compile against SDK platforms 34, 35 and 36; install
those and CMake 3.22.1 in the same SDK rather than changing plugin sources.
The verified debug APK targets ARM64:
`bash scripts/build_mobile.sh android-debug --target-platform android-arm64`.
Its Android Debug signature is for local testing, not store delivery.

`bash scripts/build_preview.sh` packages the limited public P16 preview in `dist/`.
`bash scripts/build_live.sh` packages the separate full review target there.
The latter requires ordinary server authentication/admission for member and
Admin actions; selecting a build target grants no role. Each command replaces
the previous local `dist/`; it does not publish it.

Native OAuth returns through `app.paul://login-callback`; installed invitation
links use `app.paul://invite?invite=…` or `?code=…`. Allow the exact OAuth return in
the target Supabase project's Auth settings. Verified HTTPS App Links/Universal
Links additionally require the eventual domain and client signing identifiers;
the custom scheme does not claim to provide an automatic store-install handoff.

Native notifications initialize from the platform Firebase configuration or the
public build parameters `PAUL_FIREBASE_API_KEY`, `PAUL_FIREBASE_APP_ID`,
`PAUL_FIREBASE_MESSAGING_SENDER_ID`, `PAUL_FIREBASE_PROJECT_ID` and optional
`PAUL_FIREBASE_IOS_BUNDLE_ID`. Incomplete configuration is rejected; an unconfigured
development build runs without notifications. Supply server FCM credentials only
to the worker environment and upload the client's APNs key to Firebase, never
to Dart defines or source. Both main and background isolates use the same public
configuration. A system permission request occurs only after server admission.

The new session-admission and native-push migrations/functions must be installed
together with their matching server handlers before full mobile acceptance.
Follow [the coordinated backend rollout](docs/MOBILE_BACKEND_ROLLOUT.md): the
published v27 cannot complete new registration against the new backend alone.
`native-push-worker` stays inactive until its provider credentials are configured.
The two notification bodies are `New message` and `New Hiring request`; they
contain no sender, skill or conversation text. Android's notification artwork
reuses the existing Figma Chat icon. iOS enables the Push Notifications capability
and remote-notification background mode; actual delivery still needs signed
client configuration and physical devices.
For iOS Simulator: `flutter build ios --simulator --debug --no-codesign`.
For Android: `flutter build apk --debug`.

Native OAuth returns to `app.paul://login-callback`; allowlist that exact URL in Supabase. `app.paul://invite?code=...` carries an invitation into an installed app. HTTPS universal/app links require the client domain association and signing identifiers; store installation is not assumed to retain an invite. Temporary debug bundle IDs are not approved store IDs.

## Checks and build

```sh
dart format --output=none --set-exit-if-changed lib test
flutter analyze --no-pub --fatal-infos
flutter test --no-pub --coverage
bash scripts/build_demo.sh
```

The build script produces the browser app in `dist/`. To review the release build locally, serve `dist/` with a local static server.

For an explicit source handoff, run `bash scripts/build_demo.sh --include-source`. The separate archive is written to `build/paul-demo-source.zip`. It includes only tracked application paths. Project documents and local scratch files are excluded. Publish only `dist/` for a browser preview.

Packaging regression checks run with `python3 -m unittest discover -s scripts -p 'test_package_demo.py' -v`.
Database/concurrency scripts require their explicitly isolated test containers;
they are not unittest-discovery modules.

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
| `lib/config/` | Explicit primary app, limited preview, review and demo targets |
| `lib/platform/` | Mobile SQLite, owned photo recovery, OAuth/invitation links, contacts, Share/SMS and native push |
| `ios/`, `android/` | Mobile hosts with development identifiers and separate client signing |
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

The web integration uses **supabase_flutter 2.18.3**, Supabase Auth, Postgres, private avatar Storage and the `invitations` Edge function. Use the staged schema and worker activation sequence described in Browser Web Push below. The migration versions match the verified hosted history. The function validates the user through Supabase Auth and alone can execute its service-role RPCs.

Build with a local JSON configuration containing `PAUL_LIVE`, `SUPABASE_URL`, `SUPABASE_PUBLISHABLE_KEY` and `PAUL_APP_URL`. The URL must be the actual browser origin. Only the publishable key belongs in this configuration.

```sh
bash scripts/build_live.sh --dart-define-from-file=/absolute/path/to/live.json
```

The script produces `dist/` from an isolated build with its own asset manifest. The guest preview bundles the provided Paul and Julia portraits. Member portraits load from private Storage.

Ordinary invitations last exactly 15 minutes. An open QR screen automatically replaces expired QR and numeric code. Multiple users can redeem within that lifetime. Reissuing the same token retains the original deadline. The server checks expiry again after Auth, activates membership/profile and creates a unique connection atomically.

Owner activation uses a separate one-use, seven-day invitation issued only by the trusted provisioning operator. It is bound to the intended Google email and an explicit list of existing managed profiles. The Edge function derives the confirmed email from Auth's verified Google identity; editable request/profile metadata cannot grant access. Successful registration atomically creates the member, owner role, assigned-profile grants and audit record, without adding referral credit. A retry by the same account reuses the claim and cannot restore a revoked role. Ordinary QR codes never grant Admin. Keep the raw owner link in a private local file and deliver it only to its intended recipient.

Supabase persists the main browser session across reopening. Pending invitation, profile snapshot and OAuth-finalization marker use sessionStorage. Logout clears the live pending state and onboarding draft. The current preview uses the SDK's JavaScript-readable browser storage.

The test Google provider is configured and real browser OAuth has returned successfully on Mac. Full invited-member registration and physical-phone acceptance are tracked separately. Apple is paused pending an active Developer Program account. Server account deletion is implemented in #72. Test fixture password sessions are confined to verification.

Focused local checks include `test/invitation_controller_test.dart`, `test/live_app_auth_test.dart` and `supabase/tests/invitations.sql`. `scripts/test_live_invitations.py` runs against explicitly prepared disposable QA identities supplied through a private fixture. Its basic phase requires fresh inactive invitees. Keep fixture contents, tokens and invitation links out of command output and commits.

## Browser Web Push server

The `push` Edge Function provides public `config` discovery and authenticated `subscribe`, `status`, `unsubscribe` and `resolve` actions. The server verifies Auth identity, the JWT session against `auth.sessions`, active membership and current per-conversation permissions. Managed recipients resolve to current operators with an active role and `can_reply` grant. Each browser binding belongs to one Auth user and session. Repeated registration preserves its canonical ID and original history cutoff.

Push payloads contain `version: 1`, `delivery_id`, `binding_id` and `recipient_user_id`. The service worker displays fixed generic text, checks its current local binding and resolves the route through the server on click. The original message text and profile details stay in the authorized chat API.

Private server configuration can use `PAUL_PUSH_ENABLED`, `PAUL_VAPID_PUBLIC_KEY`, `PAUL_VAPID_PRIVATE_KEY`, `PAUL_VAPID_SUBJECT`, `PAUL_PUSH_ALLOWED_ORIGINS` and `PAUL_PUSH_WORKER_SECRET`. When environment credentials are absent, Edge generates candidate keys in memory and provisions the fixed `paul_web_push_runtime` Vault entry through a service-only RPC. A database lock preserves one canonical pair across cold starts, with `enabled` initially false. Only the public VAPID key appears in discovery. Service-only `push_config_set_enabled(boolean)` activates delivery explicitly. Neither browser callers nor administrative commands receive private credentials. Both functions use application-level authorization and require deployment with gateway JWT verification disabled.

`push-worker` requires the private worker bearer. A request processes at most four claims, two concurrently, with five-second SQL HTTP and provider timeouts. The initial lease is 60 seconds. A fresh authorization preflight fences each claim, renews its lease to 30 seconds and supplies a conservative remaining-time budget. Stale or expired fences cannot disclose endpoints or complete work. Failed transient deliveries retry up to five attempts with bounded backoff. HTTP 404/410 disables the exact binding. Endpoints use the explicit HTTPS FCM/Mozilla/Apple allowlist, with redirects disabled.

Dispatch attempts expire 24 hours after the outbox event, and the final 30 seconds are excluded from dispatch. Opening an existing notification uses current authorization independently of event age. Provider TTL is 300 seconds. The browser deduplication ledger retains IDs for 26 hours, with an 8192-entry fail-closed cap and age-based pruning. Messages, outbox rows and audit remain stored. Unknown network commits reuse the delivery ID and provider topic. Client-side deduplication covers repeated delivery, while fresh binding and click authorization guard queued notifications across logout or permission changes.

Hosted activation is staged. Apply the 13 application-schema migrations through `20261110153957_web_push_vault_config.sql`, deploy the reviewed Edge functions, and let Edge provision disabled canonical Vault settings. Confirm disabled discovery and authorization checks, then explicitly enable the boolean setting. Only afterward apply `supabase/migrations/20261110154303_schedule_web_push_worker.sql`. This Supabase-specific operational migration enables `pg_cron`/`pg_net` and schedules the existing project worker every minute. It reads credentials from the fixed Vault entry and replaces only the job named `paul-web-push-worker`. Disable that exact cron job and the enabled flag to stop delivery. Apply the follow-up `20261110172505_web_push_route_authorization.sql` before accepting notification routing. It preserves the dispatch limits and checks old notification routes through current permissions.

The empty plain-Postgres unit bootstrap runs 20 application migrations. Exclude `20261110154303_schedule_web_push_worker.sql` and `20261111050427_schedule_maintenance_worker.sql` from that isolated bootstrap. Both Supabase-specific scheduling migrations have hosted gates checking actual cron runs and worker HTTP responses. All 22 migration versions remain recorded in hosted history.

Local checks use `supabase/tests/web_push.sql`, `scripts/test_push_concurrency.py`, and `supabase/functions/push/handler_test.ts`. The concurrency script accepts only isolated Paul push database names. Deno dependency locks pin the push library and transitive dependencies. Real Chrome provider delivery passed for ordinary and operator recipients, including closed application tabs while Chrome remained running. The application click handlers passed synthetic-event and URL tests. A genuine operating-system notification tap and the final browser/device matrix remain open acceptance criteria in #69/#41.

## Live text chat

The `chat` Edge function verifies every bearer with Auth and calls service-only RPCs. Apply the chat migrations in order, then deploy `supabase/functions/chat/index.ts` together with `handler.ts`. Participants alone can read persistent conversations, roster and messages. Direct contacts and existing dialogues are exempt from the new-recipient quota. The first successful message consumes that quota for an external recipient. Two completed personal invitations unlock unrestricted messaging. Self-chat is rejected. Message text supports 2000 grapheme clusters within 64 KiB of UTF-8, preserves its original payload and excludes NUL or blank-only input.

Realtime Settings must have Allow public access disabled. The Paul project is configured this way. `test_live_chat_realtime.ts` accepts `--require-private-only` after the two fixture paths to verify that authenticated public-mode and anonymous default-mode subscriptions are both rejected while authorized private signals still work.

`lib/live/chat_api.dart` exposes list/open/history/send/read/disconnect. History uses strict sequence cursors and bounded pages. Repeating an author/conversation/client-message ID returns the same message. Changing its text conflicts. A private notification event is stored in the same transaction as each new message. Deleting a connection retains the existing dialogue. Reconnecting requires fresh messages from both participants after removal. Repeated removal uses its original operation ID, and cannot delete a connection recreated since that operation.

`LiveChatController` persists the operation ID, exact text and account-scoped drafts in the current tab’s sessionStorage before sending. A failed acknowledgement remains retryable across reload of that tab. Different tabs keep independent journals. A new tab that copies its opener’s session state safely retries the same operation ID. Private Realtime inboxes send metadata-only invalidations, and the client fetches authorized history again on subscription/reconnect. The membership host calls pause/resume with visibility, closes the active conversation on departure and disposes the controller on account replacement. Pending text becomes sent only after server acknowledgement or recovery of the persisted message.

The isolated SQL gates are `supabase/tests/chat.sql` and `chat_realtime.sql`. `bootstrap.sql` is a minimal stand-in for an empty local Postgres container and must stay local. `scripts/test_chat_concurrency.py` accepts its explicit container name. Live HTTP and Realtime runners require public configuration and a private, explicitly assigned disposable QA fixture. The browser UI is integrated and under acceptance. Its two-account HTTPS gate passed history, unread/read, lost acknowledgement, manual same-UUID retry, independent tab journals/drafts, connection removal/restoration and cross-tab logout with zero page errors. The outbox feeds the browser Web Push worker described above. System notification activation and the final device matrix retain separate acceptance criteria.

## Next production stage

See the [MVP backlog](docs/MVP_BACKLOG.md) for the remaining acceptance criteria and integration dependencies.

## Design reference

[Supplied Figma file](https://www.figma.com/design/8tCP0Pg2UghSOPP5bIg9Ra/UI?node-id=2034-3242). Implemented flows include profile creation/editing, public profile/skill views, local chat and the demonstration QR / Contact access stage.
