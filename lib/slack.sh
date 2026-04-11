#!/bin/bash
# slack.sh — Slack Web API: post, delete, upload

SLACK_API="https://slack.com/api"

slack_post() {
  local channel="$1"
  local text="$2"
  local response ts

  response=$(curl -sf -X POST "$SLACK_API/chat.postMessage" \
    -H "Authorization: Bearer $SLACK_BOT_TOKEN" \
    -H "Content-Type: application/json; charset=utf-8" \
    -d "$(jq -n --arg ch "$channel" --arg txt "$text" \
      '{channel: $ch, text: $txt}')" 2>/dev/null) || true

  ts=$(echo "$response" | jq -r '.ts // empty')
  echo "$ts"
}

slack_delete() {
  local channel="$1"
  local ts="$2"
  [ -z "$ts" ] && return
  curl -sf -X POST "$SLACK_API/chat.delete" \
    -H "Authorization: Bearer $SLACK_BOT_TOKEN" \
    -H "Content-Type: application/json" \
    -d "$(jq -n --arg ch "$channel" --arg ts "$ts" \
      '{channel: $ch, ts: $ts}')" &>/dev/null || true
}

slack_upload_file() {
  local channel="$1"
  local filepath="$2"
  local filename="$3"
  local thread_ts="${4:-}"

  local params
  params=(-F "channels=$channel" -F "filename=$filename" -F "file=@$filepath")
  [ -n "$thread_ts" ] && params+=(-F "thread_ts=$thread_ts")

  curl -sf -X POST "$SLACK_API/files.upload" \
    -H "Authorization: Bearer $SLACK_BOT_TOKEN" \
    "${params[@]}" &>/dev/null || true
}

alert_active() {
  local text="$1"
  slack_post "$SLACK_ACTIVE_CHANNEL" "$text"
}

resolve_active() {
  local ts="$1"
  slack_delete "$SLACK_ACTIVE_CHANNEL" "$ts"
}

alert_log() {
  local text="$1"
  slack_post "$SLACK_LOG_CHANNEL" "$text"
}

alert_digest() {
  local text="$1"
  slack_post "$SLACK_DIGEST_CHANNEL" "$text"
}

upload_diagnostic() {
  local thread_ts="$1"
  local filepath="$2"
  local filename="$3"
  slack_upload_file "$SLACK_ACTIVE_CHANNEL" "$filepath" "$filename" "$thread_ts"
  rm -f "$filepath"
}

fmt_first_failure() {
  local tenant="$1" issue_key="$2" detail="$3" duration="$4"
  echo "🟡 *${tenant}* — ${issue_key}
  ${detail}
  Down for: ${duration}"
}

fmt_reboot_escalation() {
  local tenant="$1" issue_key="$2" duration="$3"
  echo "🔴 *${tenant}* — ${issue_key} unrecoverable
  Service has been unreachable for ${duration}. Rebooting Mac Mini in 60 seconds.
  To cancel: SSH in and kill the watchdog's shutdown subprocess."
}

fmt_recovery() {
  local tenant="$1" issue_key="$2" duration="$3"
  echo "🟢 *${tenant}* — ${issue_key} recovered
  Was down for ${duration}"
}

fmt_cpu_alert() {
  local tenant="$1" cpu_pct="$2" top_procs="$3"
  echo "⚠️ *${tenant}* — high CPU (${cpu_pct}% sustained)
${top_procs}"
}

fmt_disk_alert() {
  local tenant="$1" issue_key="$2" detail="$3"
  echo "⚠️ *${tenant}* — ${issue_key}
  ${detail}"
}

fmt_ssd_missing() {
  local tenant="$1"
  echo "🔴 *${tenant}* — /Volumes/Replays unmounted
  External SSD is missing from disk list. Recording may be falling back to boot drive. Manual intervention required."
}

fmt_log_rotated() {
  local tenant="$1" detail="$2"
  echo "ℹ️ *${tenant}* — log rotated
  ${detail}"
}

fmt_weekly_digest() {
  local tenant="$1" silent="$2" reboots="$3" period_start="$4" period_end="$5"
  echo "📊 *Weekly Report — ${tenant}*
${period_start} – ${period_end} | Full report attached.
• Silent crashes: ${silent}  |  Reboots: ${reboots}"
}

send_heartbeat() {
  [ -z "$UPTIME_ROBOT_HEARTBEAT_URL" ] && return
  curl -sf --max-time 5 "$UPTIME_ROBOT_HEARTBEAT_URL" &>/dev/null || true
  state_set_field "lastHeartbeatAt" "$(date +%s)"
}
