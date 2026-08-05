#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
METADATA_FILE="$ROOT_DIR/Scripts/build-metadata.env"

fail() {
  echo "ghostty-preflight: $*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "missing required command: $1"
}

load_metadata() {
  [ -f "$METADATA_FILE" ] || fail "missing metadata file: $METADATA_FILE"

  OMNIWM_GHOSTTY_ARCHIVE_RELATIVE_PATH=""
  OMNIWM_GHOSTTY_ARCHIVE_SHA256=""

  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      ''|'#'*) continue ;;
      *=*) ;;
      *) fail "invalid metadata line: $line" ;;
    esac

    key="${line%%=*}"
    value="${line#*=}"

    case "$key" in
      OMNIWM_GHOSTTY_ARCHIVE_RELATIVE_PATH)
        case "$value" in
          Frameworks/GhosttyKit.xcframework/macos-arm64/libghostty-internal-fat.a|\
	          Frameworks/GhosttyKit.xcframework/macos-arm64/libghostty-internal.a)
            OMNIWM_GHOSTTY_ARCHIVE_RELATIVE_PATH="$value"
            ;;
          *)
            fail "unexpected Ghostty archive path: $value"
            ;;
        esac
        ;;
      OMNIWM_GHOSTTY_ARCHIVE_SHA256)
        case "$value" in
          [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f])
            OMNIWM_GHOSTTY_ARCHIVE_SHA256="$value"
            ;;
          *)
            fail "invalid Ghostty SHA-256"
            ;;
        esac
        ;;
      *)
        fail "unexpected metadata key: $key"
        ;;
    esac
  done <"$METADATA_FILE"

  [ -n "$OMNIWM_GHOSTTY_ARCHIVE_RELATIVE_PATH" ] || fail "missing OMNIWM_GHOSTTY_ARCHIVE_RELATIVE_PATH"
  [ -n "$OMNIWM_GHOSTTY_ARCHIVE_SHA256" ] || fail "missing OMNIWM_GHOSTTY_ARCHIVE_SHA256"

  OMNIWM_GHOSTTY_ARCHIVE_PATH="$ROOT_DIR/$OMNIWM_GHOSTTY_ARCHIVE_RELATIVE_PATH"
  OMNIWM_GHOSTTY_ARCHIVE_DIR="$(dirname "$OMNIWM_GHOSTTY_ARCHIVE_PATH")"
}

verify_ghostty() {
  load_metadata
  require_command lipo
  require_command shasum

  [ -f "$OMNIWM_GHOSTTY_ARCHIVE_PATH" ] || fail "missing Ghostty archive at $OMNIWM_GHOSTTY_ARCHIVE_PATH"

  if ! archs="$(lipo "$OMNIWM_GHOSTTY_ARCHIVE_PATH" -archs 2>/dev/null)"; then
    lipo -info "$OMNIWM_GHOSTTY_ARCHIVE_PATH" >&2 || true
    fail "Ghostty archive must be arm64-only"
  fi

  if [ "$archs" != "arm64" ]; then
    lipo -info "$OMNIWM_GHOSTTY_ARCHIVE_PATH" >&2 || true
    fail "Ghostty archive must be arm64-only"
  fi

  actual_sha="$(shasum -a 256 "$OMNIWM_GHOSTTY_ARCHIVE_PATH" | awk '{print $1}')"
  if [ "$actual_sha" != "$OMNIWM_GHOSTTY_ARCHIVE_SHA256" ]; then
    echo "expected: $OMNIWM_GHOSTTY_ARCHIVE_SHA256" >&2
    echo "actual:   $actual_sha" >&2
    fail "Ghostty archive digest mismatch"
  fi
}

case "${1:-verify}" in
  verify)
    verify_ghostty
    ;;
  print-library-dir)
    verify_ghostty >/dev/null
    printf '%s\n' "$OMNIWM_GHOSTTY_ARCHIVE_DIR"
    ;;
  *)
    echo "Usage: Scripts/ghostty-preflight.sh [verify|print-library-dir]" >&2
    exit 2
    ;;
esac
