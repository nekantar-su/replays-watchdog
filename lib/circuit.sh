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

# Site-level alert TS — one message per site in replays-active
get_site_alert_ts() {
  jq -r '.siteAlertTs // empty' "$WATCHDOG_STATE_PATH" 2>/dev/null || echo ""
}

set_site_alert_ts() {
  local ts="$1"
  local tmp
  tmp=$(mktemp)
  jq --arg ts "$ts" '.siteAlertTs = $ts' "$WATCHDOG_STATE_PATH" > "$tmp" && mv "$tmp" "$WATCHDOG_STATE_PATH"
}

clear_site_alert_ts() {
  local tmp
  tmp=$(mktemp)
  jq '.siteAlertTs = null' "$WATCHDOG_STATE_PATH" > "$tmp" && mv "$tmp" "$WATCHDOG_STATE_PATH"
}

# Site-level log thread TS — one incident thread per site in replays-log
get_site_log_ts() {
  jq -r '.siteLogTs // empty' "$WATCHDOG_STATE_PATH" 2>/dev/null || echo ""
}

set_site_log_ts() {
  local ts="$1"
  local tmp
  tmp=$(mktemp)
  jq --arg ts "$ts" '.siteLogTs = $ts' "$WATCHDOG_STATE_PATH" > "$tmp" && mv "$tmp" "$WATCHDOG_STATE_PATH"
}

clear_site_log_ts() {
  local tmp
  tmp=$(mktemp)
  jq '.siteLogTs = null' "$WATCHDOG_STATE_PATH" > "$tmp" && mv "$tmp" "$WATCHDOG_STATE_PATH"
}
