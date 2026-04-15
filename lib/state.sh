#!/bin/bash
# state.sh — read/write watchdog-state.json

# Convert dot-notation path (e.g. "issues.camera:court-1.foo") to jq-safe path
# (e.g. ".issues[\"camera:court-1\"].foo") by wrapping segments that contain
# non-identifier characters in bracket notation.
_jq_path() {
  local raw="$1"
  /usr/bin/awk -F'.' '{
    result = ""
    for (i=1; i<=NF; i++) {
      seg = $i
      if (seg ~ /[^a-zA-Z0-9_]/) {
        result = result "[\"" seg "\"]"
      } else {
        result = result "." seg
      }
    }
    print result
  }' <<< "$raw"
}

init_state() {
  if [ ! -f "$WATCHDOG_STATE_PATH" ] || [ ! -s "$WATCHDOG_STATE_PATH" ] || ! jq empty "$WATCHDOG_STATE_PATH" 2>/dev/null; then
    local tmp
    tmp=$(mktemp)
    echo '{"issues":{},"siteAlertTs":null,"siteLogTs":null,"consecutiveIdle":0,"consecutiveUnreachable":0,"consecutiveCpuHigh":0,"pendingQueueHistory":[],"lastHeartbeatAt":0,"weeklyStartAt":0,"lastDigestSentAt":0,"weeklySilentCrashes":0,"weeklyMemoryWarnings":0,"weeklyReboots":0,"weeklyCpuTotal":0,"weeklyCpuSamples":0,"weeklyCpuPeak":0,"weeklyDiskBootPeak":0,"weeklyDiskExtPeak":0,"lastServiceUptimeSeconds":0,"lastBootTime":0,"serviceRestartBudget":4,"serviceRestartBudgetResetAt":0}' \
      > "$tmp" && mv "$tmp" "$WATCHDOG_STATE_PATH"
  fi
}

# state_get_field "issues[\"camera:court-1\"].consecutiveFailures"
state_get_field() {
  local path="$1"
  init_state
  jq -r ".$path // empty" "$WATCHDOG_STATE_PATH" 2>/dev/null || echo ""
}

# state_get_field_default "issues[\"camera:court-1\"].consecutiveFailures" "0"
state_get_field_default() {
  local path="$1"
  local default="$2"
  local val
  val=$(state_get_field "$path")
  echo "${val:-$default}"
}

# state_set_field "issues.camera:court-1.consecutiveFailures" "3"
# Note: jq path uses dot notation with string keys quoted internally
state_set_field() {
  local jq_path="$1"
  local value="$2"
  local jq_key
  jq_key=$(_jq_path "$jq_path")
  local tmp
  tmp=$(mktemp)
  init_state
  if echo "$value" | grep -qE '^-?[0-9]+(\.[0-9]+)?$'; then
    # numeric
    jq "${jq_key} = ($value)" "$WATCHDOG_STATE_PATH" > "$tmp" && mv "$tmp" "$WATCHDOG_STATE_PATH"
  elif echo "$value" | grep -qE '^\[|^\{'; then
    # JSON array or object — use --argjson to preserve structure
    jq --argjson v "$value" "${jq_key} = \$v" "$WATCHDOG_STATE_PATH" > "$tmp" && mv "$tmp" "$WATCHDOG_STATE_PATH"
  else
    # string
    jq --arg v "$value" "${jq_key} = \$v" "$WATCHDOG_STATE_PATH" > "$tmp" && mv "$tmp" "$WATCHDOG_STATE_PATH"
  fi
}

# state_append_to_array "issues[\"camera:court-1\"].attempts" "1712000000"
state_append_to_array() {
  local jq_path="$1"
  local value="$2"
  local tmp
  tmp=$(mktemp)
  init_state
  if echo "$value" | grep -qE '^-?[0-9]+(\.[0-9]+)?$'; then
    jq ".$jq_path = ((.$jq_path // []) + [$value])" "$WATCHDOG_STATE_PATH" > "$tmp" && mv "$tmp" "$WATCHDOG_STATE_PATH"
  else
    jq --arg v "$value" ".$jq_path = ((.$jq_path // []) + [\$v])" "$WATCHDOG_STATE_PATH" > "$tmp" && mv "$tmp" "$WATCHDOG_STATE_PATH"
  fi
}

# state_increment "consecutiveIdle"
state_increment() {
  local jq_path
  jq_path=$(_jq_path "$1")
  local tmp
  tmp=$(mktemp)
  init_state
  jq "$jq_path = (($jq_path // 0) + 1)" "$WATCHDOG_STATE_PATH" > "$tmp" && mv "$tmp" "$WATCHDOG_STATE_PATH"
}

# state_reset_counter "consecutiveIdle"
state_reset_counter() {
  local jq_path="$1"
  state_set_field "$jq_path" "0"
}

# Get the full issue object for a key (returns {} if not set)
get_issue() {
  local key="$1"
  init_state
  jq -c --arg k "$key" '.issues[$k] // {}' "$WATCHDOG_STATE_PATH"
}

# Save the full issue object for a key
set_issue() {
  local key="$1"
  local json="$2"
  local tmp
  tmp=$(mktemp)
  init_state
  jq --arg k "$key" --argjson v "$json" '.issues[$k] = $v' "$WATCHDOG_STATE_PATH" > "$tmp" \
    && mv "$tmp" "$WATCHDOG_STATE_PATH"
}

# Delete an issue key (on recovery)
clear_issue() {
  local key="$1"
  local tmp
  tmp=$(mktemp)
  init_state
  jq --arg k "$key" 'del(.issues[$k])' "$WATCHDOG_STATE_PATH" > "$tmp" && mv "$tmp" "$WATCHDOG_STATE_PATH"
}
