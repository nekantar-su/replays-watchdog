#!/bin/bash
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/helpers.sh"
source "$SCRIPT_DIR/../lib/config.sh"
source "$SCRIPT_DIR/../lib/health.sh"
source "$SCRIPT_DIR/../lib/checks.sh"

export WATCHDOG_STATE_PATH=$(mktemp)
source "$SCRIPT_DIR/../lib/state.sh"

export THRESHOLD_EXT_DISK=90
export THRESHOLD_BOOT_DISK=85
export THRESHOLD_BOOT_DISK_MIN_GB=10
export THRESHOLD_CPU=80
export THRESHOLD_CPU_CHECKS=3
export PENDING_QUEUE_GROWTH_CHECKS=3
export IDLE_GRACE_CHECKS=2

# --- Camera checks ---
HEALTH_CAMERAS='[{"cameraId":"court-1","isRunning":true,"isHealthy":false,"recentFiles":[]},{"cameraId":"court-2","isRunning":true,"isHealthy":true,"recentFiles":["f.mp4"]}]'

result=$(check_cameras)
assert_contains "camera:court-1" "$result" "unhealthy camera detected"

# Healthy camera should NOT appear in output
unhealthy_result=$(check_cameras)
if echo "$unhealthy_result" | grep -qF "court-2"; then
  echo "❌ FAIL: healthy camera should not be flagged"
  FAIL_COUNT=$((FAIL_COUNT + 1))
else
  echo "✅ PASS: healthy camera not flagged"
  PASS_COUNT=$((PASS_COUNT + 1))
fi

# --- >50% rule ---
HEALTH_CAMERAS='[{"cameraId":"court-1","isRunning":false,"isHealthy":false,"recentFiles":[]},{"cameraId":"court-2","isRunning":false,"isHealthy":false,"recentFiles":[]},{"cameraId":"court-3","isRunning":true,"isHealthy":true,"recentFiles":["f"]}]'
result=$(check_cameras)
assert_contains "cameras:all" "$result" ">50% failure triggers cameras:all"

# --- SSD mount check ---
HEALTH_DISK_MOUNTS='[{"mount":"/","use":20,"size":245107195904,"available":195618469888}]'
result=$(check_disk)
assert_contains "disk:external" "$result" "missing SSD detected"

# --- Boot disk full ---
HEALTH_DISK_MOUNTS='[{"mount":"/","use":87,"size":245107195904,"available":8589934592},{"mount":"/Volumes/Replays","use":43,"size":2000189177856,"available":1132884303872}]'
result=$(check_disk)
assert_contains "disk:boot:full" "$result" "boot disk >85% detected"

rm -f "$WATCHDOG_STATE_PATH"
print_summary
