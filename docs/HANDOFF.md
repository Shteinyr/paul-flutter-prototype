# Delivery and reproduction

The repository is a professional-networking engineering case study. Original development history is retained; the current public entry uses the existing offline demo.

## Reproduce

Use Flutter 3.47.9 / Dart 3.13.7, resolve the lockfile, and run with PAUL_TARGET=demo. The README contains Android, iOS Simulator and browser instructions. The demo has no backend dependency and uses fictional local data and simulated conversations.

## Full implementation

The app, preview and review targets retain server authentication and invitation admission. Configure your own Supabase and provider accounts. The migrations, Edge Functions, SQL checks and deployment notes remain in source. Never add server credentials to client settings.

## Boundaries

Android APK availability is separate from Google Play publication. An iOS Simulator build is separate from signed physical-iPhone distribution. Native OAuth, contacts/photo permissions, actual push delivery/tap and store acceptance require target-device verification.

The original commercial project stopped before a public store launch. Do not infer customer acceptance, adoption or financial impact from build/test results. No continuing service or feature commitment is implied.

## Repository process

Issues define one result and acceptance criteria. Focused branches and PRs preserve the reasoning and validation. Published history is not rewritten. New materials are English; old commits/discussions may remain Russian. Hosted GitHub Actions stay disabled unless separately authorised.
