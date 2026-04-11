#!/bin/bash
# diagnostics.sh — collect tier1 and tier2 snapshots to a temp file

collect_tier1() {
  local tenant="$1"
  local issue_key="$2"
  local tmp
  tmp=$(mktemp /tmp/watchdog-diag-XXXXXX.txt)

  {
    echo "=== Replays Watchdog Diagnostic — Tier 1 ==="
    echo "Tenant:    $tenant"
    echo "Issue:     $issue_key"
    echo "Time:      $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    echo ""

    echo "=== Health Endpoint ==="
    if [ -n "$HEALTH_JSON" ]; then
      echo "$HEALTH_JSON" | jq .
    else
      echo "(service unreachable)"
    fi
    echo ""

    echo "=== Log Tail (last 30 lines) ==="
    local log_file="$RS_LOG_DIR/replays-service-launchd.log"
    if [ -f "$log_file" ]; then
      tail -30 "$log_file"
    else
      echo "(log file not found at $log_file)"
    fi
    echo ""

    echo "=== Running Processes ==="
    ps -A -o pid,pcpu,pmem,comm -r | head -16
    echo ""

    echo "=== Service Processes ==="
    ps -A -o pid,pcpu,pmem,comm | grep -E "replays-service|mediamtx|gst-launch|ffmpeg" || echo "(none found)"

  } > "$tmp"

  echo "$tmp"
}

collect_tier2() {
  local tenant="$1"
  local issue_key="$2"
  local tmp
  tmp=$(collect_tier1 "$tenant" "$issue_key")

  {
    echo ""
    echo "=== Disk Info (/Volumes/Replays) ==="
    if [ -d "/Volumes/Replays" ]; then
      diskutil info /Volumes/Replays 2>/dev/null || echo "(diskutil failed)"
    else
      echo "(/Volumes/Replays not mounted)"
    fi
    echo ""

    echo "=== Memory Pressure ==="
    vm_stat
    echo ""

    echo "=== Chunk File Counts Per Camera ==="
    local chunk_dir
    if [ -d "/Volumes/Replays/chunks" ]; then
      chunk_dir="/Volumes/Replays/chunks"
    else
      chunk_dir="$RS_DATA_DIR/chunks"
    fi
    if [ -d "$chunk_dir" ]; then
      for cam_dir in "$chunk_dir"/*/; do
        local cam_name count
        cam_name=$(basename "$cam_dir")
        count=$(find "$cam_dir" -name "*.mp4" 2>/dev/null | wc -l | tr -d ' ')
        echo "  $cam_name: $count chunks"
      done
    else
      echo "(chunk directory not found)"
    fi
    echo ""

    echo "=== Service Version ==="
    echo "$HEALTH_JSON" | jq -r '[.checks[] | select(.name=="version") | .data] | first // "unknown"'

  } >> "$tmp"

  echo "$tmp"
}
