# Development process

## Issues and acceptance

Use one issue per independently verifiable outcome, or label a larger item as an epic. State the problem, screen group, intended behaviour, scope, dependencies, acceptance steps and validation evidence.

Statuses: Todo → Ready → In progress → Review → Awaiting acceptance → Accepted. Record blockers explicitly. A merge or successful test is not human acceptance.

## Branches and pull requests

- Keep main reproducible. Use focused feature/, fix/, docs/ or chore/ branches.
- Make small descriptive commits and preserve published history.
- Describe the concrete problem and resulting behaviour in each PR.
- Include relevant checks, runtime screenshots for UI changes and material limitations.
- Use Refs #N while acceptance is outstanding.
- Review the diff and run relevant local checks before merging.

## Validation and configuration

Run formatting checks, analysis, appropriate Flutter tests, packaging checks and target builds locally. SQL/Edge checks use isolated test data.

The Flutter checks GitHub Actions workflow is intentionally disabled. Do not enable, dispatch or rerun hosted workflows without separate explicit authorisation naming the repository and workflow.

Never commit service keys, tokens, signing material, real address books or private conversations. Client keys do not replace server authorisation. The standalone demo uses fictional data; full integrations require your own configuration.

## Releases

Name the source revision, build target, validation and limitations. Distinguish Android APKs, Simulator builds and signed iPhone distribution.

Original commits and discussions remain intact. New documentation and repository materials use English.
