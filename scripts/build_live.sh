#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
live_source="$project_root/build/live-source"

# Build the live configuration from the same sources with its own asset list.
# Fictional portrait assets account for 23 MB and belong to the demo build.
python3 - "$project_root" "$live_source" <<'PY'
from pathlib import Path
import shutil
import sys

root = Path(sys.argv[1])
stage = Path(sys.argv[2])
assert stage == root / 'build' / 'live-source'
if stage.exists():
    shutil.rmtree(stage)
stage.mkdir(parents=True)
for folder in ['lib', 'web']:
    shutil.copytree(root / folder, stage / folder)
shutil.copytree(root / 'assets', stage / 'assets', ignore=shutil.ignore_patterns('people'))
manifest = (root / 'pubspec.yaml').read_text()
assert manifest.count('    - assets/people/\n') == 1
(stage / 'pubspec.yaml').write_text(manifest.replace('    - assets/people/\n', ''))
shutil.copy2(root / 'pubspec.lock', stage / 'pubspec.lock')
PY

(
  cd "$live_source"
  flutter pub get --enforce-lockfile
  flutter build web --release --no-web-resources-cdn --no-wasm-dry-run \
    --pwa-strategy=none --dart-define=PAUL_LIVE=true "$@"
)
python3 - "$project_root" "$live_source" <<'PY'
from pathlib import Path
import shutil
import sys

root, stage = map(Path, sys.argv[1:])
output = root / 'dist'
if output.exists():
    shutil.rmtree(output)
shutil.copytree(stage / 'build' / 'web', output)
print('Packaged live Flutter browser build in dist/.')
PY
