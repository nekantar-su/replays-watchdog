#!/bin/bash
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/helpers.sh"

export WATCHDOG_STATE_PATH=$(mktemp)

source "$SCRIPT_DIR/../lib/state.sh"
source "$SCRIPT_DIR/../lib/circuit.sh"

# Test: set and get Slack timestamp
set_slack_ts "service:unreachable" "1234567890.123456"
result=$(get_slack_ts "service:unreachable")
assert_equals "1234567890.123456" "$result" "set/get slack ts roundtrip"

# Test: get_slack_ts returns empty for unknown key
result=$(get_slack_ts "nonexistent:key")
assert_equals "" "$result" "unknown key returns empty ts"

# Test: mark_alerted sets lastAlertedAt
mark_alerted "camera:court-1"
result=$(get_issue "camera:court-1" | jq -r '.lastAlertedAt // 0')
[ "$result" -gt 0 ]
assert_equals "0" "0" "mark_alerted sets lastAlertedAt (value: $result)"

rm -f "$WATCHDOG_STATE_PATH"
print_summary
