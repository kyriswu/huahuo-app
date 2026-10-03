#!/bin/sh
# Build-phase gate; independent of whether Xcode scheme pre-actions ran.
set -eu
TARGET="${FLUTTER_TARGET:-lib/main.dart}"
FORMAL=0
case "$TARGET" in
  lib/main.dart|"${SRCROOT}/../lib/main.dart"|"${FLUTTER_APPLICATION_PATH:-$SRCROOT/..}/lib/main.dart") FORMAL=1 ;;
esac
ALLOW_TEST=0
if [ "${CONFIGURATION:-}" = Debug ] &&
   [ "${ACTION:-build}" != install ] && [ "${ACTION:-build}" != archive ] &&
   [ "${HUAHUO_ALLOW_NON_FORMAL_FLUTTER_TARGET:-0}" = 1 ]; then
  ALLOW_TEST=1
fi
if [ "$FORMAL" = 0 ] && [ "$ALLOW_TEST" = 0 ]; then
  echo 'error: This build requires lib/main.dart. Non-formal targets are allowed only in explicitly opted-in Debug tests.' >&2
  exit 1
fi
if [ "$ALLOW_TEST" = 0 ]; then
  OLD_IFS="$IFS"
  IFS=','
  for ENCODED in ${DART_DEFINES:-}; do
    DECODED=$(printf '%s' "$ENCODED" | /usr/bin/base64 -D) || exit 1
    case "$DECODED" in
      BLE_RELAY_HARDWARE_TEST=true|HUAHUO_LOCAL_NUMERIC_AUTH=*|HUAHUO_V3_DEMO_AUTH=*|HUAHUO_V3_INITIAL_ROUTE=*|HUAHUO_CANVAS_DEBUG_REMOTE_DIFF=*|HUAHUO_BOOT_PROBE=*|HUAHUO_V3_OPEN_PROFILE_PANEL=*|HUAHUO_V3_OPEN_ADD_MENU=*)
        echo 'error: Test/demo Dart defines are forbidden in this build. Regenerate the formal Flutter configuration.' >&2
        exit 1 ;;
    esac
  done
  IFS="$OLD_IFS"
fi
