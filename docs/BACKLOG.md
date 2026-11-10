# Backlog по блокам Figma

Каждый пункт открыт до согласования и проверки production-критериев. Локальный прототип не закрывает серверные работы. Все оценки: **не оценено**.

## Предварительные этапы

- [M1 — Profile, Auth & Onboarding](https://github.com/Shteinyr/paul-flutter-prototype/milestone/1)
- [M2 — Invites, Contacts, Chat & Push](https://github.com/Shteinyr/paul-flutter-prototype/milestone/2)
- [M3 — Admin, Search & Community](https://github.com/Shteinyr/paul-flutter-prototype/milestone/3)

Подзадачи G01–G32 связаны с существующими epics. GH01 ведёт настройку и подготовку клиентского доступа отдельно. Статус draft сохраняется до согласования конкретного этапа. Общие друзья, growth-ограничения и полный guest web остаются поздними фазами.

## Существующие блоки

- [ ] [#2](https://github.com/Shteinyr/paul-flutter-prototype/issues/2) **P01 — Profile creation — Test**. Статус базы: Прототип готов. [Требования и приёмка](PROJECT_SPEC.md#p01)
- [ ] [#3](https://github.com/Shteinyr/paul-flutter-prototype/issues/3) **P02 — Profile creation — Next**. Статус базы: Прототип готов. [Требования и приёмка](PROJECT_SPEC.md#p02)
- [ ] [#4](https://github.com/Shteinyr/paul-flutter-prototype/issues/4) **P03 — Profile view → GitHub setup**. Статус базы: Прототип готов. [Требования и приёмка](PROJECT_SPEC.md#p03)
- [ ] [#5](https://github.com/Shteinyr/paul-flutter-prototype/issues/5) **P04 — QR code generation → Cloud setup**. Серверные QR/код/15 минут реализованы. Лимиты, offline-решение, реальный OAuth и устройства открыты. [Требования и приёмка](PROJECT_SPEC.md#p04)
- [ ] [#6](https://github.com/Shteinyr/paul-flutter-prototype/issues/6) **P05 — Contact access**. Clipboard/Share/доступные выбранные контакты реализованы. Устройства и отдельно согласуемое сопоставление #70 открыты. [Требования и приёмка](PROJECT_SPEC.md#p05)
- [ ] [#7](https://github.com/Shteinyr/paul-flutter-prototype/issues/7) **P06 — Registration / Splash screen → Firebase**. Гостевой просмотр и серверная последовательность регистрации реализованы. Реальный OAuth #22, Terms/Privacy #71, удаление #72 и доступ #77 открыты. [Требования и приёмка](PROJECT_SPEC.md#p06)
- [ ] [#8](https://github.com/Shteinyr/paul-flutter-prototype/issues/8) **P07 — Getting Started — offered skills 1/3**. Free-text шаг реализован. Каталог и продуктовые правила #45/#28 согласуются отдельно. [Требования и приёмка](PROJECT_SPEC.md#p07)
- [ ] [#9](https://github.com/Shteinyr/paul-flutter-prototype/issues/9) **P08 — Searching Skills — 2/3**. Отдельный optional free-text шаг реализован. Каталог и продуктовые правила #45/#28 согласуются отдельно. [Требования и приёмка](PROJECT_SPEC.md#p08)
- [ ] [#10](https://github.com/Shteinyr/paul-flutter-prototype/issues/10) **P09 — About You — 3/3**. Форма и серверная загрузка фото реализованы. Cleanup #73, реальные picker и OAuth проверки открыты. [Требования и приёмка](PROJECT_SPEC.md#p09)
- [ ] [#11](https://github.com/Shteinyr/paul-flutter-prototype/issues/11) **P10 — Chat — Push → Firebase / WebSocket setup**. Серверный чат и Web Push включены в main `0eec05f`, Sites v15. Реальные доставки проверены, системный tap, устройства, правила связей и клиентская приёмка открыты в #69/#41/#36/#37. [Требования и приёмка](PROJECT_SPEC.md#p10)
- [ ] [#12](https://github.com/Shteinyr/paul-flutter-prototype/issues/12) **P11 — Admin + User management**. Техническая приёмка #42–#44 пройдена, main `101f703`. Клиентская приёмка, реальная роль Пола #77, штатное первое обращение #76 и окончательное удаление #43 открыты. [Требования и приёмка](PROJECT_SPEC.md#p11)
- [ ] [#13](https://github.com/Shteinyr/paul-flutter-prototype/issues/13) **P12 — Skill search + Filter**. Техническая приёмка #45/#46 пройдена для собственного профиля и прямых контактов. Окончательная аудитория и клиентская приёмка открыты. [Требования и приёмка](PROJECT_SPEC.md#p12)
- [ ] [#14](https://github.com/Shteinyr/paul-flutter-prototype/issues/14) **P13 — Community reach out — Local**. Статус базы: Запланировано. [Требования и приёмка](PROJECT_SPEC.md#p13)
- [ ] [#15](https://github.com/Shteinyr/paul-flutter-prototype/issues/15) **P14 — Connections — Search — Hiring — Chat**. Статус базы: Частично. [Требования и приёмка](PROJECT_SPEC.md#p14)
- [ ] [#16](https://github.com/Shteinyr/paul-flutter-prototype/issues/16) **P15 — Pop-ups**. Статус базы: Частично. [Требования и приёмка](PROJECT_SPEC.md#p15)
- [ ] [#17](https://github.com/Shteinyr/paul-flutter-prototype/issues/17) **P16 — Web view — Prompts / Guest → Profile — React Online**. Статус базы: Запланировано. [Требования и приёмка](PROJECT_SPEC.md#p16)

Порядок: согласование scope и backend → доступы/окружения → auth/profile → messaging/connections → push/invites/contacts → согласованные discovery/admin/community/web.
