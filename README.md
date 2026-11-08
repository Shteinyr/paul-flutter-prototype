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

В этом репозитории опубликованы документация, задачи и шаблоны. Исходники Flutter и CI подготовлены к отдельному импорту; GitHub Actions ещё не запускался. Проверенная локальная база: 24 теста, анализ без замечаний, форматирование и release web build.

## Порядок работы

Issue → согласованные критерии и оценка → отдельная ветка → PR → проверки → приёмка. Статусы: Backlog → Ready → In progress → Review → Done. Срок 100 часов / две недели — ограничение клиента; окончательный состав поставки и оценки ещё не утверждены.

Репозиторий private. Платные облачные сервисы и production-доступы не подключены.
