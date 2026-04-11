#!/bin/bash
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/helpers.sh"

# Use a temp state file for tests
export WATCHDOG_STATE_PATH=$(mktemp)
source "$SCRIPT_DIR/../lib/state.sh"

# Test: state file is created when missing
rm -f "$WATCHDOG_STATE_PATH"
init_state
assert_equals "0" "$(jq '.issues | length' "$WATCHDOG_STATE_PATH")" "init creates empty issues"

# Test: set and get a string value
state_set_field "issues.camera:court-1.consecutiveFailures" "3"
result=$(state_get_field "issues[\"camera:court-1\"].consecutiveFailures")
assert_equals "3" "$result" "state set/get consecutiveFailures"

# Test: append to array
state_append_to_array "issues[\"camera:court-1\"].attempts" "1712000000"
state_append_to_array "issues[\"camera:court-1\"].attempts" "1712000300"
count=$(jq '."issues"."camera:court-1".attempts | length' "$WATCHDOG_STATE_PATH")
assert_equals "2" "$count" "state append to array"

# Test: get missing field returns default
result=$(state_get_field_default "issues[\"camera:court-99\"].consecutiveFailures" "0")
assert_equals "0" "$result" "missing field returns default"

rm -f "$WATCHDOG_STATE_PATH"
print_summary
