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
    first_failed=$now
  fi

  local duration
  duration=$(human_duration "$(seconds_since "$first_failed")")

  local existing_ts
  existing_ts=$(get_slack_ts "$key")

  # Already have an active alert — check for 30-min reboot escalation (service only)
  if [ -n "$existing_ts" ]; then
    case "$key" in
      service:unreachable|service:down)
        local already_rebooting
        already_rebooting=$(echo "$issue" | jq -r '.rebootScheduled // false')
        if [ "$already_rebooting" != "true" ] && [ "$ALLOW_REBOOT" = "true" ]; then
          local time_down
          time_down=$((now - first_failed))
          if [ "$time_down" -ge 1800 ]; then
            local escalation_msg
            escalation_msg=$(fmt_reboot_escalation "$TENANT" "$key" "$duration")
            resolve_active "$existing_ts"
            local new_ts
            new_ts=$(alert_active "$escalation_msg")
            set_slack_ts "$key" "$new_ts"
            alert_log "$escalation_msg"
            issue=$(echo "$issue" | jq '.rebootScheduled = true')
            set_issue "$key" "$issue"
            log "REBOOT ESCALATION: $key unreachable for $duration — rebooting in 60s"
            (
              sleep 60
              alert_log ":arrows_counterclockwise: *[$TENANT] Rebooting now.*"
              log "REBOOTING NOW"
              sudo /sbin/shutdown -r now
            ) &
          fi
        fi
        ;;
    esac
    log "ONGOING: $key — down $duration"
    return
  fi

  # First time seeing this failure — post yellow alert with tier1 diagnostics
  local diag_file
  diag_file=$(collect_tier1 "$TENANT" "$key")
  local msg
  msg=$(fmt_first_failure "$TENANT" "$key" "$detail" "$duration")
  local new_ts
  new_ts=$(alert_active "$msg")
  set_slack_ts "$key" "$new_ts"
  upload_diagnostic "$new_ts" "$diag_file" "diagnostic-${TENANT}-${key//:/--}-tier1.txt"
  alert_log "$msg"
  mark_alerted "$key"
  log "NEW FAILURE: $key — $detail"
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

  local ts
  ts=$(get_slack_ts "$key")
  [ -n "$ts" ] && resolve_active "$ts"

  alert_log "$(fmt_recovery "$TENANT" "$key" "$duration")"
  log "RECOVERED: $key — was down $duration"

  clear_issue "$key"
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
    ext_use=$(get_disk_mount "/Volumes/Replays" | jq -r '.use // 0' | cut -d. -f1)
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
  slack_upload_file "$SLACK_DIGEST_CHANNEL" "$report_file" "weekly-report-${TENANT}-$(date '+%Y-%m-%d').txt" "$summary_ts"
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

  if [ "$HEALTH_STATUS" != "unreachable" ]; then
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

  # 5. Heartbeat
  send_heartbeat
  maybe_send_weekly_digest

  local failure_count
  failure_count=$(wc -l < "$failures_file" 2>/dev/null || echo 0)
  rm -f "$failures_file"

  log "Poll cycle complete. Active issues: $failure_count"
}

main
