#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
project="ruang-chat-mobile-test-$$"
cleanup() { API_PORT=18081 SEED_DEMO=false docker compose -p "$project" down -v >/dev/null 2>&1 || true; }
trap cleanup EXIT
API_PORT=18081 SEED_DEMO=false docker compose -p "$project" up -d --build --wait
cd mobile
flutter drive --driver=test_driver/integration_test.dart --target=integration_test/chat_test.dart -d "${1:-emulator-5554}" --dart-define=API_BASE_URL=http://10.0.2.2:18081
