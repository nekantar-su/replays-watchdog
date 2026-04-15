#!/bin/bash
# checks.sh — all check functions. Each echoes "issue_key|detail" lines for failures only.

check_cameras() {
  local total
  total=$(camera_count)
  [ "$total" -eq 0 ] && return

  local unhealthy_count
  unhealthy_count=$(unhealthy_camera_count)

  # >50% rule: skip individual restarts, flag as group
  if [ "$unhealthy_count" -gt 0 ] && [ "$((unhealthy_count * 2))" -gt "$total" ]; then
    echo "cameras:all|$unhealthy_count of $total cameras unhealthy simultaneously"
    return
  fi

  # Individual camera failures
  local camera_json id is_running is_healthy
  while IFS= read -r camera_json; do
    id=$(echo "$camera_json" | jq -r '.cameraId')
    is_running=$(echo "$camera_json" | jq -r '.isRunning')
    is_healthy=$(echo "$camera_json" | jq -r '.isHealthy')
    if [ "$is_running" = "false" ]; then
      echo "camera:$id|not running (isRunning=false)"
    elif [ "$is_healthy" = "false" ]; then
      echo "camera:$id|no recent chunks (isRunning=true but isHealthy=false)"
    fi
  done < <(echo "$HEALTH_CAMERAS" | jq -c '.[]')
}

check_service_status() {
  case "$HEALTH_STATUS" in
    unreachable)
      local consecutive
      consecutive=$(state_get_field_default "consecutiveUnreachable" "0")
      consecutive=$((consecutive + 1))
      state_set_field "consecutiveUnreachable" "$consecutive"
      if [ "$consecutive" -ge 2 ]; then
        echo "service:unreachable|health endpoint did not respond (${consecutive} consecutive checks)"
      fi
      ;;
    down)
      state_reset_counter "consecutiveUnreachable"
      echo "service:down|status=down (critical infrastructure failure)"
      ;;
    idle)
      state_reset_counter "consecutiveUnreachable"
      local consecutive
      consecutive=$(state_get_field_default "consecutiveIdle" "0")
      consecutive=$((consecutive + 1))
      state_set_field "consecutiveIdle" "$consecutive"
      if [ "$consecutive" -ge "$IDLE_GRACE_CHECKS" ]; then
        local unhealthy_count
        unhealthy_count=$(unhealthy_camera_count)
        if [ "$unhealthy_count" -eq 0 ]; then
          echo "service:idle|status=idle for ${consecutive} checks (cameras not started)"
        fi
      fi
      ;;
    recording)
      state_reset_counter "consecutiveUnreachable"
      state_reset_counter "consecutiveIdle"
      ;;
  esac
}

check_disk() {
  # External SSD presence
  if [ "$(external_ssd_present)" = "false" ]; then
    echo "disk:external|/Volumes/Replays not mounted — SSD may be disconnected"
  else
    local ssd_path ext_use
    [ -d "/Volumes/REPLAYS" ] && ssd_path="/Volumes/REPLAYS" || ssd_path="/Volumes/Replays"
    ext_use=$(get_disk_use_pct "$ssd_path")
    if [ "${ext_use:-0}" -ge "$THRESHOLD_EXT_DISK" ]; then
      echo "disk:external:full|$ssd_path is ${ext_use}% used"
    fi
  fi

  local boot_use boot_available_bytes boot_available_gb
  boot_use=$(get_disk_mount "/" | jq -r '.use // 0' | cut -d. -f1)
  boot_available_bytes=$(get_disk_mount "/" | jq -r '.available // 0')
  boot_available_gb=$(echo "$boot_available_bytes / 1073741824" | bc)

  if [ "$boot_use" -ge "$THRESHOLD_BOOT_DISK" ]; then
    echo "disk:boot:full|/ is ${boot_use}% used, ${boot_available_gb}GB remaining"
  elif [ "$boot_available_gb" -lt "$THRESHOLD_BOOT_DISK_MIN_GB" ]; then
    echo "disk:boot:full|/ has only ${boot_available_gb}GB remaining"
  fi
}

check_gcp() {
  [ "$HEALTH_EXT_STORAGE" = "down" ] || return
  local network_ok
  network_ok=$(check_network_connectivity)
  if [ "$network_ok" = "true" ]; then
    echo "gcp|externalStorage=down, internet is up — GCP may be unreachable"
  else
    echo "gcp|externalStorage=down, internet also down — site has no connectivity"
  fi
}

check_network_connectivity() {
  ping -c 1 -t 3 8.8.8.8 &>/dev/null && echo "true" || echo "false"
}

check_cpu() {
  local idle_pct cpu_pct
  idle_pct=$(top -l 1 -n 0 | awk '/CPU usage/ {gsub(/%/,""); print $(NF-1)}')
  cpu_pct=$(echo "100 - $idle_pct" | bc | cut -d. -f1)

  if [ "$cpu_pct" -ge "$THRESHOLD_CPU" ]; then
    state_increment "consecutiveCpuHigh"
    local consecutive
    consecutive=$(state_get_field_default "consecutiveCpuHigh" "0")
    if [ "$consecutive" -ge "$THRESHOLD_CPU_CHECKS" ]; then
      local top_procs
      top_procs=$(ps -A -o pcpu,comm -r | head -6 | tail -5 | \
        awk '{printf "  %-10s %s%%\n", $2, $1}')
      echo "cpu|${cpu_pct}% sustained ${consecutive} checks (~${consecutive}min)|$top_procs"
    fi
  else
    state_reset_counter "consecutiveCpuHigh"
  fi
}

check_pending_queue() {
  local queue_path="$RS_DATA_DIR/pending-clips.json"
  [ -f "$queue_path" ] || return
  local count
  count=$(jq 'length' "$queue_path" 2>/dev/null)
  count="${count:-0}"

  local history
  history=$(state_get_field "pendingQueueHistory")
  [ -z "$history" ] && history="[]"
  history=$(echo "$history" | jq --argjson c "$count" --argjson n "${PENDING_QUEUE_GROWTH_CHECKS}" '. + [$c] | .[-$n:]')
  state_set_field "pendingQueueHistory" "$history"

  local history_length
  history_length=$(echo "$history" | jq 'length')
  [ "$history_length" -lt "$PENDING_QUEUE_GROWTH_CHECKS" ] && return

  local is_growing
  is_growing=$(echo "$history" | jq '. as $a | [range(1;length)] | all($a[.] > $a[.-1])')
  if [ "$is_growing" = "true" ] && [ "$count" -gt 0 ]; then
    echo "clips:queue|pending clips queue growing (now $count clips) — possible GCP upload issue"
  fi
}

check_and_rotate_logs() {
  local max_bytes=$((THRESHOLD_LOG_MB * 1024 * 1024))
  local log_file
  for log_file in "$RS_LOG_DIR"/*.log; do
    [ -f "$log_file" ] || continue
    local size
    size=$(stat -f%z "$log_file" 2>/dev/null || echo "0")
    if [ "$size" -ge "$max_bytes" ]; then
      mv "$log_file" "${log_file}.bak"
      touch "$log_file"
      echo "log:rotated|$(basename "$log_file") was ${size} bytes, rotated"
    fi
  done
  # Delete old .bak files once per cycle (outside the loop)
  find "$RS_LOG_DIR" -name "*.log.bak" -mtime +7 -delete 2>/dev/null || true

  # Remove .DS_Store files from video directories — macOS creates these
  # silently and they interfere with the replay service's file iteration
  find /Volumes/Replays/cache -name ".DS_Store" -delete 2>/dev/null || true
  find /Volumes/Replays/chunks -name ".DS_Store" -delete 2>/dev/null || true
}
