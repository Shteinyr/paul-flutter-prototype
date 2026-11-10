# Continuation checkpoint

## Current P11 checkpoint, 2026-11-10

P11 #42–#44 is technically accepted and merged in main `101f703d4191b9dc5d521072e493bcc127d3f4a4`. Its Git tree matches reviewed source `797b141edf33407d09769b3444b6f246966f152a`. The live browser runtime SHA256 is `a45deb2ab76e8907cbc04b5c61e388d2c5ff7648e5824565691b976a81d71e21`.

Admin roles, assigned managed-profile commands, private photos, audit, reversible disable and the operator inbox/manual reply-as are implemented. Every request uses current server authorization. Messages retain both the real Auth actor and managed sender. Existing identities, ordinary chat visibility and history are preserved.

Local verification passed 144 VM tests, 6 Chrome tests, 19 Deno endpoint tests, 2 packaging checks, analysis, formatting and demo/live release builds. The fresh 11-migration chain, nine SQL suites and concurrent ordinary/admin/operator operations passed, including real service-role execution. Independent full browser runs by the second reviewer and coordinator both passed with zero page errors. They covered actual binary Realtime delivery, lost ACK and exact retry after reload, mounted disable/restore, private denials, actor/sender persistence, Contacts search and logout/identity guards.

Final browser-only publication uses the existing test Site. The QA cleanup contract removes temporary roles, grants and two isolated connections after the coordinator closes the public verification window. QA identities, conversations and audit are retained. Client acceptance remains open. Real Paul access awaits verified Auth identity. Managed-profile audience, presentation, material rights and final deletion require client decisions. Google/Apple OAuth, Terms/Privacy and background push retain their separate criteria. Paul has created an Apple Developer account, while Program membership, account type, agreements and developer access remain unverified.

Alexander requested a pause after P11 publication and cleanup. P13 and further services require a new instruction. Continue from current main and the P11 section of [PROJECT_SPEC.md](PROJECT_SPEC.md#p11). The older import checkpoint below is historical.

## Goal and sources

- Repository: https://github.com/Shteinyr/paul-flutter-prototype
- Source import branch: `chore/import-flutter-prototype`.
- Product scope: [PROJECT_SPEC.md](PROJECT_SPEC.md), blocks P01–P16, tracked in issues #2–17.
- Prototype review instructions: [DEMO_WALKTHROUGH.md](DEMO_WALKTHROUGH.md).
- Development process: [CONTRIBUTING.md](../CONTRIBUTING.md).

## Verified source baseline

Flutter 3.47.9 / Dart 3.13.7. On 2026-11-08 the imported source passed locked dependency resolution, formatting (18 files, no changes), static analysis, all 24 tests and a release web build. The build script also produced the browser preview and downloadable source archive.

This is a local prototype: profile editing/persistence, contacts, public profiles, skills, local chat, and QR/invitation/notification demonstrations. Real authentication, cross-account messaging, native push and device contact integration remain backlog work; do not mark the corresponding epics complete from this import.

## Resume without previous chat history

1. Inspect the latest repository state and the import pull request before making changes; work may have advanced since this checkpoint.
2. Confirm that the complete Flutter source and `.github/workflows/flutter-ci.yml` are committed on the import branch or merged into `main`.
3. Inspect existing GitHub Actions results for that exact commit. Flutter checks is disabled as of 2026-11-09. Starting or enabling a hosted run requires Alexander's explicit approval naming this repository and workflow. Use local checks until approval is available.
4. Fix failures from available checks in the same branch and report their exact commit and origin. Keep local verification and hosted CI results distinct.
5. Do not recreate the repository, duplicate issues #2–17 or reimplement the prototype. Do not send a client message or connect production services without a separate instruction.

Keep source and checkpoints in Git. Transfer file contents directly between the filesystem and tools; return only concise summaries to the conversation, never Base64 data or full file dumps.

## Repository setup on 2026-11-09

The existing repository is private. The preserved P01–P16 epics have 33 technical sub-issues and three draft milestones. Native runners and real backend services remain outstanding. Main requires a pull request, resolved conversations and no force pushes or deletion. A second approving reviewer is not required for this single-developer setup. Required hosted status checks are not configured while Actions is disabled.

Default browser packaging produces only `dist/`. Explicit source handoff uses `--include-source` and writes a tracked-source archive separately in `build/`. The private local onboarding package stays above the Git checkout.
