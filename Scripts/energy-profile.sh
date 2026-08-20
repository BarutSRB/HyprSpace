#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROFILER="${PROFILER:-powermetrics}"
OUTPUT_DIR="${OUTPUT_DIR:-$ROOT_DIR/.build/energy-profiles}"
TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ)"

mkdir -p "$OUTPUT_DIR"

case "$PROFILER" in
  powermetrics)
    if [ "$(id -u)" -ne 0 ]; then
      echo "powermetrics requires explicit administrator execution." >&2
      echo "Run: sudo env PROFILER=powermetrics OUTPUT_DIR='$OUTPUT_DIR' '$ROOT_DIR/Scripts/energy-profile.sh'" >&2
      exit 77
    fi
    SAMPLE_RATE_MS="${SAMPLE_RATE_MS:-5000}"
    SAMPLE_COUNT="${SAMPLE_COUNT:-60}"
    OUTPUT="$OUTPUT_DIR/omniwm-powermetrics-$TIMESTAMP.txt"
    echo "Recording $SAMPLE_COUNT powermetrics samples every ${SAMPLE_RATE_MS}ms"
    echo "Output: $OUTPUT"
    exec /usr/bin/powermetrics \
      --sample-rate "$SAMPLE_RATE_MS" \
      --sample-count "$SAMPLE_COUNT" \
      --samplers tasks,cpu_power,gpu_power \
      --show-process-energy \
      --show-process-coalition \
      --show-process-qos \
      --show-process-gpu \
      --show-usage-summary \
      --output-file "$OUTPUT"
    ;;
  *)
    echo "Unsupported PROFILER '$PROFILER'; use powermetrics." >&2
    exit 64
    ;;
esac
