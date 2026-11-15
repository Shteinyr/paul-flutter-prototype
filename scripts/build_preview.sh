#!/usr/bin/env bash
set -euo pipefail
export PAUL_WEB_TARGET=preview
exec bash "$(dirname "$0")/build_live.sh" "$@"
