#!/bin/bash
# circuit.sh — Slack message timestamp tracking and alert state helpers

# Store Slack active channel message timestamp for later deletion
set_slack_ts() {
  local key="$1"
  local ts="$2"
  local issue
  issue=$(get_issue "$key")
  issue=$(echo "$issue" | jq --arg ts "$ts" '.slackActiveTs = $ts')
  set_issue "$key" "$issue"
}

get_slack_ts() {
  local key="$1"
  get_issue "$key" | jq -r '.slackActiveTs // empty'
}

# Update lastAlertedAt timestamp
mark_alerted() {
  local key="$1"
  local now
  now=$(date +%s)
  local issue
  issue=$(get_issue "$key")
  issue=$(echo "$issue" | jq --argjson now "$now" '.lastAlertedAt = $now')
  set_issue "$key" "$issue"
}
