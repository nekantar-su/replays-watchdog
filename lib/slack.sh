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

slack_update() {
  local channel="$1"
  local ts="$2"
  local text="$3"
  [ -z "$ts" ] && return
  curl -sf -X POST "$SLACK_API/chat.update" \
    -H "Authorization: Bearer $SLACK_BOT_TOKEN" \
    -H "Content-Type: application/json; charset=utf-8" \
    -d "$(jq -n --arg ch "$channel" --arg ts "$ts" --arg txt "$text" \
      '{channel: $ch, ts: $ts, text: $txt}')" &>/dev/null || true
}

update_active() {
  local ts="$1"
  local text="$2"
  slack_update "$SLACK_ACTIVE_CHANNEL" "$ts" "$text"
}

slack_post_thread() {
  local channel="$1"
  local thread_ts="$2"
  local text="$3"
  [ -z "$thread_ts" ] && return
  curl -sf -X POST "$SLACK_API/chat.postMessage" \
    -H "Authorization: Bearer $SLACK_BOT_TOKEN" \
    -H "Content-Type: application/json; charset=utf-8" \
    -d "$(jq -n --arg ch "$channel" --arg ts "$thread_ts" --arg txt "$text" \
      '{channel: $ch, thread_ts: $ts, text: $txt}')" &>/dev/null || true
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
  local log_ts="$1"
  local filepath="$2"
  local filename="$3"
  [ ! -f "$filepath" ] && return
  [ -z "$log_ts" ] && return

  # Redact RTSP credentials before posting to Slack (full creds stay in on-disk file only)
  local tmpfile
  tmpfile=$(mktemp)
  sed -E 's|rtsp://[^@]+@|rtsp://<credentials>@|g' "$filepath" > "$tmpfile"

  local filesize
  filesize=$(wc -c < "$tmpfile" | tr -d ' ')

  # Step 1 — get upload URL
  local url_response upload_url file_id
  url_response=$(curl -sf -X POST "$SLACK_API/files.getUploadURLExternal" \
    -H "Authorization: Bearer $SLACK_BOT_TOKEN" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    --data-urlencode "filename=${filename}" \
    --data-urlencode "length=${filesize}" 2>/dev/null) || true

  upload_url=$(echo "$url_response" | jq -r '.upload_url // empty')
  file_id=$(echo "$url_response"   | jq -r '.file_id // empty')

  if [ -z "$upload_url" ] || [ -z "$file_id" ]; then
    rm -f "$tmpfile"
    # Fallback: post first 50 lines as code block if upload API fails
    local header
    header=$(sed -E 's|rtsp://[^@]+@|rtsp://<credentials>@|g' "$filepath" | head -50)
    slack_post_thread "$SLACK_LOG_CHANNEL" "$log_ts" \
      "📋 *Diagnostic Report — ${filename}*
\`\`\`
${header}
\`\`\`
_Full report saved on device: \`$filepath\`_"
    return
  fi

  # Step 2 — upload file content
  curl -sf -X POST "$upload_url" \
    -H "Content-Type: text/plain" \
    --data-binary "@$tmpfile" &>/dev/null || true

  rm -f "$tmpfile"

  # Step 3 — complete upload and share to log thread
  curl -sf -X POST "$SLACK_API/files.completeUploadExternal" \
    -H "Authorization: Bearer $SLACK_BOT_TOKEN" \
    -H "Content-Type: application/json" \
    -d "$(jq -n \
      --arg ch  "$SLACK_LOG_CHANNEL" \
      --arg ts  "$log_ts" \
      --arg fid "$file_id" \
      --arg fn  "$filename" \
      '{channel_id: $ch, thread_ts: $ts, files: [{id: $fid, title: $fn}], initial_comment: "📋 Diagnostic report (RTSP credentials redacted). Full report with credentials saved on device."}')" \
    &>/dev/null || true
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
