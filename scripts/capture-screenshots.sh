#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
gallery_image_base64=$(base64 < mobile/web/icons/Icon-512.png | tr -d '\r\n')
SCREENSHOT_OUTPUT="$PWD/docs/screenshots" ./scripts/test-mobile.sh \
  "${1:-emulator-5554}" integration_test/screenshots_test.dart \
  "--dart-define=SCREENSHOT_IMAGE_BASE64=$gallery_image_base64"
