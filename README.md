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

Локальный Flutter-прототип покрывает Profile → Contacts, публичные профили, навыки, локальный chat и демонстрации QR/Connect/уведомлений. Серверная авторизация, обмен между реальными аккаунтами, native push и синхронизация адресной книги остаются отдельными работами.

В репозитории находятся исходники Flutter, документация, задачи, шаблоны и workflow GitHub Actions. Фактический результат автоматических проверок доступен во вкладке Actions. Проверенная локальная база: 24 теста, анализ без замечаний, форматирование и release web build.

## Порядок работы

Issue → согласованные критерии и оценка → отдельная ветка → PR → проверки → приёмка. Статусы: Backlog → Ready → In progress → Review → Done. Срок 100 часов / две недели — ограничение клиента; окончательный состав поставки и оценки ещё не утверждены.

Репозиторий private. Платные облачные сервисы и production-доступы не подключены.

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

No backend account or credentials are needed to run the current prototype.

## Checks and build

```sh
dart format --output=none --set-exit-if-changed lib test
flutter analyze --no-pub --fatal-infos
flutter test --no-pub --coverage
bash scripts/build_demo.sh
```

The build script produces the browser app in `dist/` and a source download at `dist/paul-demo-source.zip`. To review the release build locally, serve `dist/` with a local static server.

The GitHub Actions workflow runs formatting, analysis, tests and a release web build on pushes to `main` and pull requests. Browser and coverage outputs are retained as private repository artifacts for seven days. A configured workflow is not a claim that a remote run has already passed; check the Actions tab after the first push.

## Code map

| Path | Responsibility |
| --- | --- |
| `lib/app.dart` | Navigation, editing forms, contacts and reusable profile/avatar widgets |
| `lib/profile/` | Profile model, persistence interface, controller, sample migration and public views |
| `lib/chat/` | Local chat state/store, connection rules, simulated replies and conversation UI |
| `lib/demo_connect.dart` | Demonstration QR / Connect / invite flow |
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

## Next production stage

See the [proposed MVP backlog](docs/MVP_BACKLOG.md) for acceptance criteria, integration dependencies and the proposed Flutter + Supabase + FCM/APNs stack. No production cloud service has been connected or billed by this prototype.

## Design reference

[Supplied Figma file](https://www.figma.com/design/8tCP0Pg2UghSOPP5bIg9Ra/UI?node-id=2034-3242). Implemented flows include profile creation/editing, public profile/skill views, local chat and the demonstration QR / Contact access stage.
