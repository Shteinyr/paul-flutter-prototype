# Backlog по блокам Figma

Каждый пункт открыт до согласования и проверки production-критериев. Локальный прототип не закрывает серверные работы. Все оценки: **не оценено**.

## Коррекция отклонённой v18

[#94](https://github.com/Shteinyr/paul-flutter-prototype/issues/94) объединяет #95 поиск, #96 вторую вкладку Hiring, #97 визуал Admin, #98 гостевые шаги/поля/возврат, #99 данные видимой приёмки, #100 QR/приглашение, #101 качество подсказок и #102 старт/общую проверку. Требования сверены с Figma и встречей до начала исправлений. Ни одна из этих задач не считается принятой по результатам прежних тестов. Реальный Google/Apple вход и аппаратная приёмка уведомлений сохраняют отдельные открытые зависимости.

## Предварительные этапы

- [M1 — Profile, Auth & Onboarding](https://github.com/Shteinyr/paul-flutter-prototype/milestone/1)
- [M2 — Invites, Contacts, Chat & Push](https://github.com/Shteinyr/paul-flutter-prototype/milestone/2)
- [M3 — Admin, Search & Community](https://github.com/Shteinyr/paul-flutter-prototype/milestone/3)

Подзадачи G01–G32 связаны с существующими epics. GH01 ведёт настройку и подготовку клиентского доступа отдельно. Статус draft сохраняется до согласования конкретного этапа. Представление общих друзей и полный P16 guest web имеют отдельные задачи. Принятые11.11.2026 уровни2/10 ведутся в текущей исполнительской #86.

## Принятая очередь реализации от 11.11.2026

- #45/#46/#76 — общий справочник со свободным вводом, глобальный поиск и штатное первое обращение к управляемым профилям.
- #86 — завершённые регистрации по личному приглашению, пороги2/10, суточная квота новых внешних собеседников и серверные права расширенных возможностей.
- #43/#72 — окончательное удаление данных после подтверждения, сохранение переписки у собеседников с подписью «Удалённый пользователь».
- #47/#48 — общая Hiring-лента, публикация после десяти приглашённых, свободное количество активных запросов, удаление при закрытии/истечении30дней и push согласившимся участникам.
- #70 — исключена решением Александра от12.11.2026: привязка телефона, SMS-подтверждение и сопоставление номеров не нужны. P05 оставляет только приглашение другу.
- #84/#85 — последующие тарифы компаний и история/статистика запросов.

Сохранённые технические проверки прежних версий учитываются отдельно от оставшейся разработки и клиентской приёмки. Внешние Google/Apple подтверждаются по фактическим настройкам и проверкам. SMS-провайдер исключён. Интерфейс принимается по мобильным экранам существующей Figma.

## Существующие блоки

- [ ] [#2](https://github.com/Shteinyr/paul-flutter-prototype/issues/2) **P01 — Profile creation — Test**. Статус базы: Прототип готов. [Требования и приёмка](PROJECT_SPEC.md#p01)
- [ ] [#3](https://github.com/Shteinyr/paul-flutter-prototype/issues/3) **P02 — Profile creation — Next**. Статус базы: Прототип готов. [Требования и приёмка](PROJECT_SPEC.md#p02)
- [ ] [#4](https://github.com/Shteinyr/paul-flutter-prototype/issues/4) **P03 — Profile view → GitHub setup**. Статус базы: Прототип готов. [Требования и приёмка](PROJECT_SPEC.md#p03)
- [ ] [#5](https://github.com/Shteinyr/paul-flutter-prototype/issues/5) **P04 — QR code generation → Cloud setup**. Серверные QR/код/15 минут реализованы. Лимиты, offline-решение, реальный OAuth и устройства открыты. [Требования и приёмка](PROJECT_SPEC.md#p04)
- [ ] [#6](https://github.com/Shteinyr/paul-flutter-prototype/issues/6) **P05 — Contact access**. Копирование, системная отправка приглашения и выбор контакта при поддержке браузера реализованы. #70 исключена; SMS-провайдер не нужен. Остаётся реальная проверка отправки/отмены/возврата на телефоне и клиентская приёмка #34/#35/#41. [Требования и приёмка](PROJECT_SPEC.md#p05)
- [ ] [#7](https://github.com/Shteinyr/paul-flutter-prototype/issues/7) **P06 — Registration / Splash screen → Firebase**. Гостевой просмотр и серверная последовательность регистрации реализованы. Удаление #72 реализовано. Реальный OAuth #22, Terms/Privacy #71 и доступ #77 открыты. [Требования и приёмка](PROJECT_SPEC.md#p06)
- [ ] [#8](https://github.com/Shteinyr/paul-flutter-prototype/issues/8) **P07 — Getting Started — offered skills 1/3**. Шаг с общим ESCO-справочником и свободным вводом реализован. Предлагаемые навыки учитывают уровень приглашений #86. [Требования и приёмка](PROJECT_SPEC.md#p07)
- [ ] [#9](https://github.com/Shteinyr/paul-flutter-prototype/issues/9) **P08 — Searching Skills — 2/3**. Необязательный шаг с общим ESCO-справочником и свободным вводом реализован. [Требования и приёмка](PROJECT_SPEC.md#p08)
- [ ] [#10](https://github.com/Shteinyr/paul-flutter-prototype/issues/10) **P09 — About You — 3/3**. Форма и серверная загрузка фото реализованы. Cleanup #73, реальные picker и OAuth проверки открыты. [Требования и приёмка](PROJECT_SPEC.md#p09)
- [ ] [#11](https://github.com/Shteinyr/paul-flutter-prototype/issues/11) **P10 — Chat — Push → Firebase / WebSocket setup**. Серверный чат и Web Push включены в main `0eec05f`, Sites v15. Реальные доставки проверены, системный tap, устройства, правила связей и клиентская приёмка открыты в #69/#41/#36/#37. [Требования и приёмка](PROJECT_SPEC.md#p10)
- [ ] [#12](https://github.com/Shteinyr/paul-flutter-prototype/issues/12) **P11 — Admin + User management**. Admin workspace, глобальное первое обращение #76 и окончательное удаление #43 реализованы. Клиентская приёмка и реальная роль Пола #77 открыты. [Требования и приёмка](PROJECT_SPEC.md#p11)
- [ ] [#13](https://github.com/Shteinyr/paul-flutter-prototype/issues/13) **P12 — Skill search + Filter**. Глобальный поиск зарегистрированных участников и общий справочник со свободным вводом #45/#46 реализованы. Клиентская приёмка открыта. [Требования и приёмка](PROJECT_SPEC.md#p12)
- [ ] [#14](https://github.com/Shteinyr/paul-flutter-prototype/issues/14) **P13 — Community reach out — Local**. Hiring/feed/create/close/30-day expiry и Web Push реализованы в #47/#48. Клиентская и системная приёмка уведомлений открыты. [Требования и приёмка](PROJECT_SPEC.md#p13)
- [ ] [#15](https://github.com/Shteinyr/paul-flutter-prototype/issues/15) **P14 — Connections — Search — Hiring — Chat**. Статус базы: Частично. [Требования и приёмка](PROJECT_SPEC.md#p14)
- [ ] [#16](https://github.com/Shteinyr/paul-flutter-prototype/issues/16) **P15 — Pop-ups**. Статус базы: Частично. [Требования и приёмка](PROJECT_SPEC.md#p15)
- [ ] [#17](https://github.com/Shteinyr/paul-flutter-prototype/issues/17) **P16 — Web view — Prompts / Guest → Profile — React Online**. Статус базы: Запланировано. [Требования и приёмка](PROJECT_SPEC.md#p16)

Порядок: согласование scope и backend → доступы/окружения → auth/profile → messaging/connections → push/invites/contacts → согласованные discovery/admin/community/web.
