#!/usr/bin/env bash
set -euo pipefail
export CI=true FLUTTER_SUPPRESS_ANALYTICS=true
flutter --suppress-analytics build web --dart-define=PAUL_TARGET=demo --release --no-web-resources-cdn --no-wasm-dry-run --pwa-strategy=none
python3 scripts/package_demo.py "$@"
