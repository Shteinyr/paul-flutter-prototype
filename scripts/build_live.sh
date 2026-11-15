#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
live_source="$project_root/build/live-source"

# Build the live configuration from the same sources with its own asset list.
# The guest preview uses Paul and Julia. Other portraits belong to the demo build.
python3 - "$project_root" "$live_source" "$@" <<'PY'
from pathlib import Path
import json
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
guest_portraits = ['paul-galda.png', 'julia-robinson.png']
(stage / 'assets/people').mkdir()
for portrait in guest_portraits:
    shutil.copy2(root / 'assets/people' / portrait, stage / 'assets/people' / portrait)
manifest = (root / 'pubspec.yaml').read_text()
assert manifest.count('    - assets/people/\n') == 1
portrait_manifest = ''.join(
    f'    - assets/people/{portrait}\n' for portrait in guest_portraits
)
(stage / 'pubspec.yaml').write_text(
    manifest.replace('    - assets/people/\n', portrait_manifest)
)
shutil.copy2(root / 'pubspec.lock', stage / 'pubspec.lock')
# Start the same anonymous first-page request during engine download. Only
# explicitly public build settings enter this bootstrap; never copy the file.
defines = {}
args = iter(sys.argv[3:])
for arg in args:
    if arg == '--dart-define-from-file':
        defines.update(json.loads(Path(next(args)).read_text()))
    elif arg.startswith('--dart-define-from-file='):
        defines.update(json.loads(Path(arg.split('=', 1)[1]).read_text()))
    elif arg == '--dart-define':
        key, value = next(args).split('=', 1)
        defines[key] = value
    elif arg.startswith('--dart-define='):
        key, value = arg.split('=', 1)[1].split('=', 1)
        defines[key] = value
settings = {
    'url': defines.get('SUPABASE_URL', ''),
    'key': defines.get('SUPABASE_PUBLISHABLE_KEY', ''),
}
config = json.dumps(settings, ensure_ascii=True).replace('<', '\\u003c')
early = (root / 'web/paul_public_preview_bootstrap.js').read_text().replace(
    '/* PAUL_PUBLIC_PREVIEW_SETTINGS */ null', config,
)
loader = stage / 'web/flutter_bootstrap.js'
loader.write_text(loader.read_text().replace('// PAUL_PUBLIC_PREVIEW_BOOTSTRAP', early))
PY

(
  cd "$live_source"
  flutter pub get --enforce-lockfile
  flutter build web --release --no-web-resources-cdn --no-wasm-dry-run \
    --pwa-strategy=none --dart-define=PAUL_TARGET=review "$@"
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
