#!/bin/bash
PASS_COUNT=0
FAIL_COUNT=0

assert_equals() {
  local expected="$1"
  local actual="$2"
  local test_name="$3"
  if [ "$expected" = "$actual" ]; then
    echo "✅ PASS: $test_name"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo "❌ FAIL: $test_name"
    echo "   Expected: [$expected]"
    echo "   Actual:   [$actual]"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
}

assert_contains() {
  local needle="$1"
  local haystack="$2"
  local test_name="$3"
  if echo "$haystack" | grep -qF "$needle"; then
    echo "✅ PASS: $test_name"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo "❌ FAIL: $test_name"
    echo "   Expected to contain: [$needle]"
    echo "   Actual: [$haystack]"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
}

print_summary() {
  echo ""
  echo "Results: $PASS_COUNT passed, $FAIL_COUNT failed"
  [ "$FAIL_COUNT" -eq 0 ] && exit 0 || exit 1
}

# Minimal health JSON for use in tests
mock_health_all_good() {
  cat <<'EOF'
{"status":"recording","checks":[{"name":"diskStorage","status":"up","data":[{"mount":"/","use":20,"size":245107195904,"available":195618469888},{"mount":"/Volumes/Replays","use":43,"size":2000189177856,"available":1132884303872}]},{"name":"memory","status":"up"},{"name":"swap","status":"up"},{"name":"cpuLoad","status":"up"},{"name":"latency","status":"up"},{"name":"cameras","status":"up","data":[{"cameraId":"court-1","isRunning":true,"isHealthy":true,"recentFiles":["file1.mp4"]},{"cameraId":"court-2","isRunning":true,"isHealthy":true,"recentFiles":["file2.mp4"]}]},{"name":"externalStorage","status":"up"}]}
EOF
}

mock_health_camera_down() {
  cat <<'EOF'
{"status":"recording","checks":[{"name":"diskStorage","status":"up","data":[{"mount":"/","use":20,"size":245107195904,"available":195618469888},{"mount":"/Volumes/Replays","use":43,"size":2000189177856,"available":1132884303872}]},{"name":"cameras","status":"up","data":[{"cameraId":"court-1","isRunning":true,"isHealthy":false,"recentFiles":[]},{"cameraId":"court-2","isRunning":true,"isHealthy":true,"recentFiles":["file2.mp4"]}]},{"name":"externalStorage","status":"up"}]}
EOF
}

mock_health_ssd_gone() {
  cat <<'EOF'
{"status":"down","checks":[{"name":"diskStorage","status":"down","data":[{"mount":"/","use":20,"size":245107195904,"available":195618469888}]},{"name":"cameras","status":"up","data":[]},{"name":"externalStorage","status":"up"}]}
EOF
}
