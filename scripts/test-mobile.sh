#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
device="${1:-emulator-5554}"
target="${2:-integration_test/chat_test.dart}"
if [ "$#" -gt 2 ]; then shift 2; else set --; fi
project="ruang-chat-mobile-test-$$"
cleanup() { API_PORT=18081 SEED_DEMO=false docker compose -p "$project" down -v >/dev/null 2>&1 || true; }
trap cleanup EXIT
API_PORT=18081 SEED_DEMO=false docker compose -p "$project" up -d --build --wait
cd mobile
flutter drive --driver=test_driver/integration_test.dart --target="$target" -d "$device" --dart-define=API_BASE_URL=http://10.0.2.2:18081 "$@"
