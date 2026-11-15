#!/usr/bin/env bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_root"
mobile_target="${1:-ios-simulator}"
if [[ $# -gt 0 ]]; then shift; fi
flutter pub get --enforce-lockfile
case "$mobile_target" in
  ios-simulator) flutter build ios --simulator --debug --no-codesign --no-pub --dart-define=PAUL_TARGET=app "$@" ;;
  ios-unsigned) flutter build ios --release --no-codesign --no-pub --dart-define=PAUL_TARGET=app "$@" ;;
  android-debug) flutter build apk --debug --no-pub --dart-define=PAUL_TARGET=app "$@" ;;
  android-bundle)
    [[ -f android/key.properties ]] || { echo 'Configure the client release signing key in android/key.properties first.' >&2; exit 1; }
    flutter build appbundle --release --no-pub --dart-define=PAUL_TARGET=app "$@" ;;
  *) echo 'Use ios-simulator, ios-unsigned, android-debug or android-bundle.' >&2; exit 2 ;;
esac
