#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

source "$SCRIPT_DIR/lib/config.sh"
source "$SCRIPT_DIR/lib/state.sh"
source "$SCRIPT_DIR/lib/circuit.sh"
source "$SCRIPT_DIR/lib/health.sh"
source "$SCRIPT_DIR/lib/checks.sh"
source "$SCRIPT_DIR/lib/diagnostics.sh"
source "$SCRIPT_DIR/lib/slack.sh"

mkdir -p "$RS_LOG_DIR"
command -v jq >/dev/null 2>&1 || { echo "ERROR: jq is required but not installed. Install with: brew install jq" >&2; exit 1; }
load_config

WATCHDOG_LOCK_PATH="$RS_DATA_DIR/watchdog.lock"

run_with_lock() {
  # macOS-compatible PID-file lock (flock is Linux-only)
  if [ -f "$WATCHDOG_LOCK_PATH" ]; then
    local existing_pid
    existing_pid=$(cat "$WATCHDOG_LOCK_PATH" 2>/dev/null)
    if [ -n "$existing_pid" ] && kill -0 "$existing_pid" 2>/dev/null; then
      log "Previous poll cycle still running (PID $existing_pid). Skipping this cycle."
      exit 0
    fi
    # Stale lock — previous run died without cleanup
    rm -f "$WATCHDOG_LOCK_PATH"
  fi
  echo $$ > "$WATCHDOG_LOCK_PATH"
  trap 'rm -f "$WATCHDOG_LOCK_PATH"' EXIT
}

TENANT=$(load_tenant_code)
BEARER_TOKEN=$(load_bearer_token)
init_state

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$WATCHDOG_LOG"
}

seconds_since() {
  local ts="$1"
  local now
  now=$(date +%s)
  echo $((now - ts))
}

human_duration() {
  local secs="$1"
  if [ "$secs" -lt 60 ]; then echo "${secs}s"
  elif [ "$secs" -lt 3600 ]; then echo "$((secs/60))m $((secs%60))s"
  else echo "$((secs/3600))h $(( (secs%3600)/60 ))m"
  fi
}

handle_failure() {
  local key="$1"
  local detail="$2"
  local now
  now=$(date +%s)

  local issue
  issue=$(get_issue "$key")

  # Record first seen time if new
  local first_failed
  first_failed=$(echo "$issue" | jq '.firstFailedAt // 0')
  if [ "$first_failed" = "0" ]; then
    issue=$(echo "$issue" | jq --argjson now "$now" '.firstFailedAt = $now')
    set_issue "$key" "$issue"
    log "NEW FAILURE: $key — $detail"
  else
    log "ONGOING: $key — down $(human_duration $((now - first_failed)))"
  fi
}

handle_recovery() {
  local key="$1"
  local issue
  issue=$(get_issue "$key")
  [ "$(echo "$issue" | jq '.firstFailedAt // 0')" = "0" ] && return

  local first_failed now duration
  first_failed=$(echo "$issue" | jq '.firstFailedAt // 0')
  now=$(date +%s)
  duration=$(human_duration $((now - first_failed)))

  log "RECOVERED: $key — was down $duration"
  clear_issue "$key"
}

# Build a single consolidated alert message from all active failures
build_site_alert_msg() {
  local failures_file="$1"
  local now="$2"

  # If service is in reboot escalation, show red escalation message
  while IFS='|' read -r key detail; do
    case "$key" in
      service:unreachable|service:down)
        local issue first_failed
        issue=$(get_issue "$key")
        if [ "$(echo "$issue" | jq -r '.rebootScheduled // false')" = "true" ]; then
          first_failed=$(echo "$issue" | jq '.firstFailedAt // 0')
          fmt_reboot_escalation "$TENANT" "$key" "$(human_duration $((now - first_failed)))"
          return
        fi
        ;;
    esac
  done < "$failures_file"

  # Determine top-level severity icon
  local icon="🟡"
  while IFS='|' read -r key detail; do
    case "$key" in service:unreachable|service:down) icon="🔴" ;; esac
  done < "$failures_file"

  local count
  count=$(grep -c '.' "$failures_file" 2>/dev/null) || count=0

  local msg="${icon} *${TENANT}* — ${count} active issue(s)"$'\n'
  while IFS='|' read -r key detail; do
    local issue first_failed duration
    issue=$(get_issue "$key")
    first_failed=$(echo "$issue" | jq '.firstFailedAt // 0')
    [ "$first_failed" != "0" ] && duration=$(human_duration $((now - first_failed))) || duration="just now"
    msg="${msg}  • ${key} — ${detail} (${duration})"$'\n'
  done < "$failures_file"

  echo "$msg"
}

# Post, update, or delete the single replays-active message for this site
# Also manages the replays-log incident thread
sync_site_alert() {
  local failures_file="$1"
  local now
  now=$(date +%s)

  local site_ts log_ts
  site_ts=$(get_site_alert_ts)
  log_ts=$(get_site_log_ts)

  local failure_count
  failure_count=$(grep -c '.' "$failures_file" 2>/dev/null) || failure_count=0

  if [ "$failure_count" -eq 0 ]; then
    # All clear — delete active message and close log thread
    if [ -n "$site_ts" ]; then
      resolve_active "$site_ts"
      clear_site_alert_ts
    fi
    if [ -n "$log_ts" ]; then
      slack_post_thread "$SLACK_LOG_CHANNEL" "$log_ts" \
        "🟢 *${TENANT}* — all issues resolved at $(date '+%-I:%M %p')"
      clear_site_log_ts
    fi
    return
  fi

  local msg
  msg=$(build_site_alert_msg "$failures_file" "$now")

  if [ -z "$site_ts" ]; then
    # First alert — post active message and open log thread
    site_ts=$(alert_active "$msg")
    set_site_alert_ts "$site_ts"

    local all_issues
    all_issues=$(awk -F'|' '{print $1}' "$failures_file" | tr '\n' ', ' | sed 's/, $//')

    log_ts=$(slack_post "$SLACK_LOG_CHANNEL" \
      "🔴 *${TENANT}* — incident started $(date '+%a %b %-d at %-I:%M %p')
Issues: ${all_issues}")
    [ -n "$log_ts" ] && set_site_log_ts "$log_ts"

    # Generate ONE diagnostic for all active issues, attach to log thread
    local diag_file
    diag_file=$(collect_tier1 "$TENANT" "$all_issues" "$failures_file")
    upload_diagnostic "$log_ts" "$diag_file" "diagnostic-${TENANT}-$(date '+%Y%m%d-%H%M%S').txt"
  else
    # Issues ongoing — update message in-place with current state and durations
    update_active "$site_ts" "$msg"
  fi
}

# Attempt LaunchAgent restart for persistent service failures, with guardrails
manage_service_recovery() {
  local failures_file="$1"
  local now
  now=$(date +%s)

  # Only act on service:down or service:unreachable
  local service_key=""
  if grep -q "^service:down|" "$failures_file" 2>/dev/null; then
    service_key="service:down"
  elif grep -q "^service:unreachable|" "$failures_file" 2>/dev/null; then
    service_key="service:unreachable"
  fi
  [ -z "$service_key" ] && return

  local issue first_failed time_down
  issue=$(get_issue "$service_key")
  first_failed=$(echo "$issue" | jq '.firstFailedAt // 0')
  [ "$first_failed" = "0" ] && return
  time_down=$((now - first_failed))

  local log_ts
  log_ts=$(get_site_log_ts)

  # ── Restart logic ────────────────────────────────────────────────────────
  local budget reset_at attempts last_restart
  budget=$(state_get_field_default "serviceRestartBudget" "4")
  reset_at=$(state_get_field_default "serviceRestartBudgetResetAt" "0")
  attempts=$(echo "$issue" | jq '.restartAttempts // 0')
  last_restart=$(echo "$issue" | jq '.lastRestartAt // 0')

  # Reset daily budget after 24 hours
  if [ "$reset_at" != "0" ] && [ $((now - reset_at)) -ge 86400 ]; then
    budget=4
    state_set_field "serviceRestartBudget" "4"
    state_set_field "serviceRestartBudgetResetAt" "$now"
  fi

  local cooldown_ok=false
  { [ "$last_restart" = "0" ] || [ $((now - last_restart)) -ge 600 ]; } && cooldown_ok=true

  if [ "$time_down" -ge 300 ] && \
     [ "$attempts" -lt 2 ] && \
     [ "$budget" -gt 0 ] && \
     [ "$cooldown_ok" = "true" ]; then

    local attempt_num=$((attempts + 1))
    log "RESTART ATTEMPT $attempt_num: $service_key down $(human_duration $time_down)"

    if [ -n "$log_ts" ]; then
      slack_post_thread "$SLACK_LOG_CHANNEL" "$log_ts" \
        "⚙️ *${TENANT}* — restart attempt ${attempt_num}/2 (down $(human_duration $time_down))"
    fi

    # Collect pre-restart diagnostic
    local all_issues diag_file
    all_issues=$(awk -F'|' '{print $1}' "$failures_file" | tr '\n' ', ' | sed 's/, $//')
    diag_file=$(collect_tier1 "$TENANT" "pre-restart-${attempt_num}: ${all_issues}" "$failures_file")

    # Update state before restart
    issue=$(echo "$issue" | jq --argjson a "$attempt_num" --argjson t "$now" \
      '.restartAttempts = $a | .lastRestartAt = $t')
    set_issue "$service_key" "$issue"
    state_set_field "serviceRestartBudget" "$((budget - 1))"
    [ "$reset_at" = "0" ] && state_set_field "serviceRestartBudgetResetAt" "$now"

    # Restart the LaunchAgent
    local plist="$HOME/Library/LaunchAgents/com.podplay.ReplaysService.plist"
    launchctl unload "$plist" 2>/dev/null || true
    sleep 3
    launchctl load "$plist" 2>/dev/null || true
    log "Restart attempt $attempt_num complete"

    # Upload diagnostic to log thread (persists after active alert is deleted)
    [ -f "$diag_file" ] && [ -n "$log_ts" ] && \
      upload_diagnostic "$log_ts" "$diag_file" "restart-${attempt_num}-diag-${TENANT}.txt"

    # Warn if daily budget now exhausted
    local new_budget=$((budget - 1))
    if [ "$new_budget" -le 0 ] && [ -n "$log_ts" ]; then
      slack_post_thread "$SLACK_LOG_CHANNEL" "$log_ts" \
        "⚠️ *${TENANT}* — daily restart budget exhausted. No more automatic restarts. Manual intervention required."
    fi
    return
  fi

  # ── Reboot escalation (30 min, only once) ────────────────────────────────
  local already_rebooting
  already_rebooting=$(echo "$issue" | jq -r '.rebootScheduled // false')
  if [ "$already_rebooting" != "true" ] && [ "$ALLOW_REBOOT" = "true" ] && [ "$time_down" -ge 1800 ]; then
    local duration
    duration=$(human_duration "$time_down")
    issue=$(echo "$issue" | jq '.rebootScheduled = true')
    set_issue "$service_key" "$issue"
    log "REBOOT ESCALATION: $service_key down $duration — rebooting in 60s"

    local escalation_msg
    escalation_msg=$(fmt_reboot_escalation "$TENANT" "$service_key" "$duration")
    if [ -n "$log_ts" ]; then
      slack_post_thread "$SLACK_LOG_CHANNEL" "$log_ts" "$escalation_msg"
    else
      alert_log "$escalation_msg"
    fi

    (
      sleep 60
      local reboot_msg=":arrows_counterclockwise: *[$TENANT] Rebooting now.*"
      [ -n "$log_ts" ] && \
        slack_post_thread "$SLACK_LOG_CHANNEL" "$log_ts" "$reboot_msg" || \
        alert_log "$reboot_msg"
      log "REBOOTING NOW"
      sudo /sbin/shutdown -r now
    ) &
  fi
}

track_silent_events() {
  # Silent crash detection — uptime reset means service crashed and auto-recovered
  if [ "$HEALTH_STATUS" != "unreachable" ] && [ "$HEALTH_UPTIME_SECONDS" -gt 0 ]; then
    local last_uptime
    last_uptime=$(state_get_field_default "lastServiceUptimeSeconds" "0")
    if [ "$last_uptime" -gt 0 ] && [ "$HEALTH_UPTIME_SECONDS" -lt "$last_uptime" ]; then
      state_increment "weeklySilentCrashes"
      log "SILENT CRASH detected — uptime reset from ${last_uptime}s to ${HEALTH_UPTIME_SECONDS}s"
    fi
    state_set_field "lastServiceUptimeSeconds" "$HEALTH_UPTIME_SECONDS"
  fi

  # Memory warning tracking
  if [ "$HEALTH_MEMORY_STATUS" = "down" ]; then
    state_increment "weeklyMemoryWarnings"
  fi

  # Reboot detection via boot time
  local current_boot
  current_boot=$(sysctl -n kern.boottime 2>/dev/null | awk '{print $4}' | tr -d ',')
  local last_boot
  last_boot=$(state_get_field_default "lastBootTime" "0")
  if [ -n "$current_boot" ]; then
    if [ "$last_boot" != "0" ] && [ "$current_boot" != "$last_boot" ]; then
      state_increment "weeklyReboots"
      log "REBOOT detected — boot time changed"
    fi
    if [ "$last_boot" = "0" ] || [ "$current_boot" != "$last_boot" ]; then
      state_set_field "lastBootTime" "$current_boot"
    fi
  fi
}

track_system_samples() {
  # CPU sample
  local idle_pct cpu_pct
  idle_pct=$(top -l 1 -n 0 2>/dev/null | awk '/CPU usage/ {gsub(/%/,""); print $(NF-1)}')
  [ -z "$idle_pct" ] && return
  cpu_pct=$(echo "100 - $idle_pct" | bc | cut -d. -f1)

  local tmp
  tmp=$(mktemp)
  jq --argjson cpu "$cpu_pct" '
    .weeklyCpuTotal = ((.weeklyCpuTotal // 0) + $cpu) |
    .weeklyCpuSamples = ((.weeklyCpuSamples // 0) + 1) |
    .weeklyCpuPeak = (if $cpu > (.weeklyCpuPeak // 0) then $cpu else (.weeklyCpuPeak // 0) end)
  ' "$WATCHDOG_STATE_PATH" > "$tmp" && mv "$tmp" "$WATCHDOG_STATE_PATH"

  # Disk samples (reuse already-polled health data)
  if [ "$HEALTH_STATUS" != "unreachable" ]; then
    local boot_use ext_use
    boot_use=$(get_disk_mount "/" | jq -r '.use // 0' | cut -d. -f1)
    local ssd_path
    [ -d "/Volumes/REPLAYS" ] && ssd_path="/Volumes/REPLAYS" || ssd_path="/Volumes/Replays"
    ext_use=$(get_disk_use_pct "$ssd_path")
    [ -z "$boot_use" ] && boot_use=0
    [ -z "$ext_use" ] && ext_use=0

    tmp=$(mktemp)
    jq --argjson boot "$boot_use" --argjson ext "$ext_use" '
      .weeklyDiskBootPeak = (if $boot > (.weeklyDiskBootPeak // 0) then $boot else (.weeklyDiskBootPeak // 0) end) |
      .weeklyDiskExtPeak = (if $ext > (.weeklyDiskExtPeak // 0) then $ext else (.weeklyDiskExtPeak // 0) end)
    ' "$WATCHDOG_STATE_PATH" > "$tmp" && mv "$tmp" "$WATCHDOG_STATE_PATH"
  fi
}

generate_weekly_report() {
  local out_file="$1"
  local week_start
  week_start=$(jq -r '.weeklyStartAt // 0' "$WATCHDOG_STATE_PATH")
  local period_start period_end
  period_start=$(date -r "$week_start" '+%b %-d, %Y')
  period_end=$(date '+%b %-d, %Y')

  local silent mem reboots
  silent=$(jq -r '.weeklySilentCrashes // 0' "$WATCHDOG_STATE_PATH")
  mem=$(jq -r '.weeklyMemoryWarnings // 0' "$WATCHDOG_STATE_PATH")
  reboots=$(jq -r '.weeklyReboots // 0' "$WATCHDOG_STATE_PATH")

  local cpu_total cpu_samples cpu_avg cpu_peak disk_boot disk_ext
  cpu_total=$(jq -r '.weeklyCpuTotal // 0' "$WATCHDOG_STATE_PATH")
  cpu_samples=$(jq -r '.weeklyCpuSamples // 0' "$WATCHDOG_STATE_PATH")
  cpu_peak=$(jq -r '.weeklyCpuPeak // 0' "$WATCHDOG_STATE_PATH")
  disk_boot=$(jq -r '.weeklyDiskBootPeak // 0' "$WATCHDOG_STATE_PATH")
  disk_ext=$(jq -r '.weeklyDiskExtPeak // 0' "$WATCHDOG_STATE_PATH")
  if [ "$cpu_samples" -gt 0 ]; then
    cpu_avg=$(echo "$cpu_total / $cpu_samples" | bc)
  else
    cpu_avg=0
  fi

  {
    echo "Replays Weekly Report — $TENANT"
    echo "Period: $period_start – $period_end"
    echo "Generated: $(date '+%a %b %-d, %Y at %-I:%M %p')"
    echo ""
    echo "EVENTS (auto-recovered — no action needed)"
    printf "  %-30s %s\n" "Service silent crashes:" "$silent"
    printf "  %-30s %s\n" "Memory warnings:" "$mem"
    printf "  %-30s %s\n" "Mac Mini reboots:" "$reboots"
    echo ""
    echo "SYSTEM HEALTH"
    printf "  %-30s %s%%\n" "Avg CPU:" "$cpu_avg"
    printf "  %-30s %s%%\n" "Peak CPU:" "$cpu_peak"
    printf "  %-30s %s%% peak\n" "Disk (boot):" "$disk_boot"
    printf "  %-30s %s%% peak\n" "Disk (external):" "$disk_ext"
    echo ""
    [ "$silent" -eq 0 ] && [ "$reboots" -eq 0 ] && \
      echo "All clear — no issues this week."
  } > "$out_file"
}


maybe_send_weekly_digest() {
  local now
  now=$(date +%s)
  local week_secs=$((7 * 24 * 3600))

  local week_start
  week_start=$(jq -r '.weeklyStartAt // 0' "$WATCHDOG_STATE_PATH")

  # Initialize week start if never set
  if [ "$week_start" = "0" ]; then
    state_set_field "weeklyStartAt" "$now"
    return
  fi

  local elapsed=$((now - week_start))
  [ "$elapsed" -lt "$week_secs" ] && return

  # 7 days have passed — send digest and reset
  local silent reboots
  silent=$(jq -r '.weeklySilentCrashes // 0' "$WATCHDOG_STATE_PATH")
  reboots=$(jq -r '.weeklyReboots // 0' "$WATCHDOG_STATE_PATH")

  local period_start period_end
  period_start=$(date -r "$week_start" '+%b %-d, %Y')
  period_end=$(date '+%b %-d, %Y')

  # Build report file and post to Slack
  local report_file
  report_file=$(mktemp /tmp/weekly-report-XXXXXX.txt)
  generate_weekly_report "$report_file"

  local summary_ts
  summary_ts=$(alert_digest "$(fmt_weekly_digest "$TENANT" "$silent" "$reboots" "$period_start" "$period_end")")
  if [ -n "$summary_ts" ]; then
    local report_content
    report_content=$(cat "$report_file")
    slack_post_thread "$SLACK_DIGEST_CHANNEL" "$summary_ts" "\`\`\`
${report_content}
\`\`\`"
  fi
  rm -f "$report_file"

  log "WEEKLY DIGEST SENT: $silent silent crashes, $reboots reboots over 7 days"

  # Reset for next week
  local tmp
  tmp=$(mktemp)
  jq --argjson now "$now" '
    .weeklyStartAt = $now |
    .lastDigestSentAt = $now |
    .weeklySilentCrashes = 0 |
    .weeklyMemoryWarnings = 0 |
    .weeklyReboots = 0 |
    .weeklyCpuTotal = 0 |
    .weeklyCpuSamples = 0 |
    .weeklyCpuPeak = 0 |
    .weeklyDiskBootPeak = 0 |
    .weeklyDiskExtPeak = 0
  ' "$WATCHDOG_STATE_PATH" > "$tmp" && mv "$tmp" "$WATCHDOG_STATE_PATH"
}

main() {
  run_with_lock
  log "Poll cycle"

  # 1. Poll health endpoint
  poll_health

  # 2. Track silent events and system samples for weekly digest
  track_silent_events
  track_system_samples

  # 3. Collect all current failures into a temp file (bash 3.x compatible)
  local failures_file
  failures_file=$(mktemp)

  while IFS='|' read -r key detail; do
    [ -z "$key" ] && continue
    echo "$key|$detail" >> "$failures_file"
  done < <(check_service_status)

  if [ "$HEALTH_STATUS" != "unreachable" ] && [ "$HEALTH_STATUS" != "down" ]; then
    while IFS='|' read -r key detail; do
      [ -z "$key" ] && continue
      echo "$key|$detail" >> "$failures_file"
    done < <(check_cameras)

    while IFS='|' read -r key detail; do
      [ -z "$key" ] && continue
      echo "$key|$detail" >> "$failures_file"
    done < <(check_disk)

    while IFS='|' read -r key detail; do
      [ -z "$key" ] && continue
      echo "$key|$detail" >> "$failures_file"
    done < <(check_gcp)
  fi

  while IFS='|' read -r key detail; do
    [ -z "$key" ] && continue
    echo "$key|$detail" >> "$failures_file"
  done < <(check_cpu)

  while IFS='|' read -r key detail; do
    [ -z "$key" ] && continue
    echo "$key|$detail" >> "$failures_file"
  done < <(check_pending_queue)

  while IFS='|' read -r key detail; do
    [ -z "$key" ] && continue
    alert_log "$(fmt_log_rotated "$TENANT" "$detail")"
  done < <(check_and_rotate_logs)

  # 3. Handle recoveries — tracked issues no longer failing
  local tracked_keys
  tracked_keys=$(jq -r '.issues | keys[]' "$WATCHDOG_STATE_PATH" 2>/dev/null || echo "")
  for key in $tracked_keys; do
    if ! grep -qF "$key|" "$failures_file" 2>/dev/null; then
      handle_recovery "$key"
    fi
  done

  # 4. Handle active failures
  while IFS='|' read -r key detail; do
    [ -z "$key" ] && continue
    handle_failure "$key" "$detail"
  done < "$failures_file"

  # 5. Sync the single replays-active message for this site
  sync_site_alert "$failures_file"

  # 6. Attempt service restart if eligible
  manage_service_recovery "$failures_file"

  # 7. Heartbeat
  send_heartbeat
  maybe_send_weekly_digest

  local failure_count
  failure_count=$(grep -c '.' "$failures_file" 2>/dev/null) || failure_count=0
  rm -f "$failures_file"

  log "Poll cycle complete. Active issues: $failure_count"
}

main
