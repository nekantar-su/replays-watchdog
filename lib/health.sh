#!/bin/bash
# health.sh — poll /health and expose parsed variables

# After calling poll_health, these globals are set:
# HEALTH_STATUS          — "recording" | "idle" | "down" | "unreachable"
# HEALTH_JSON            — raw JSON string (empty if unreachable)
# HEALTH_CAMERAS         — JSON array of camera objects
# HEALTH_DISK_MOUNTS     — JSON array of disk mount objects
# HEALTH_EXT_STORAGE     — "up" | "down"
# HEALTH_UPTIME_SECONDS  — service uptime in seconds (0 if unreachable)
# HEALTH_MEMORY_STATUS   — "up" | "down"

poll_health() {
  HEALTH_JSON=""
  HEALTH_STATUS="unreachable"
  HEALTH_CAMERAS="[]"
  HEALTH_DISK_MOUNTS="[]"
  HEALTH_EXT_STORAGE="up"
  HEALTH_UPTIME_SECONDS=0
  HEALTH_MEMORY_STATUS="up"

  local response
  response=$(curl -sf --max-time "$HEALTH_TIMEOUT" "$HEALTH_URL" 2>/dev/null) || true

  if [ -z "$response" ]; then
    HEALTH_STATUS="unreachable"
    return
  fi

  HEALTH_JSON="$response"
  HEALTH_STATUS=$(echo "$HEALTH_JSON" | jq -r '.status // "unreachable"')

  HEALTH_CAMERAS=$(echo "$HEALTH_JSON" | \
    jq -c '[.checks[] | select(.name=="cameras") | .data // []] | flatten')

  HEALTH_DISK_MOUNTS=$(echo "$HEALTH_JSON" | \
    jq -c '[.checks[] | select(.name=="diskStorage") | .data // []] | flatten')

  HEALTH_EXT_STORAGE=$(echo "$HEALTH_JSON" | \
    jq -r '[.checks[] | select(.name=="externalStorage") | .status] | first // "up"')

  HEALTH_UPTIME_SECONDS=$(echo "$HEALTH_JSON" | \
    jq -r '[.checks[] | select(.name=="uptime") | .data.uptimeSeconds] | first // 0')

  HEALTH_MEMORY_STATUS=$(echo "$HEALTH_JSON" | \
    jq -r '[.checks[] | select(.name=="memory") | .status] | first // "up"')
}

camera_count() {
  echo "$HEALTH_CAMERAS" | jq 'length'
}

get_camera() {
  local id="$1"
  echo "$HEALTH_CAMERAS" | jq -c --arg id "$id" '.[] | select(.cameraId == $id)'
}

all_camera_ids() {
  echo "$HEALTH_CAMERAS" | jq -r '.[].cameraId'
}

unhealthy_camera_count() {
  echo "$HEALTH_CAMERAS" | jq '[.[] | select(.isHealthy == false or .isRunning == false)] | length'
}

unhealthy_cameras() {
  echo "$HEALTH_CAMERAS" | jq -c '[.[] | select(.isHealthy == false or .isRunning == false)]'
}

get_disk_mount() {
  local mount="$1"
  echo "$HEALTH_DISK_MOUNTS" | jq -c --arg m "$mount" '.[] | select(.mount == $m)'
}

external_ssd_present() {
  local count
  count=$(echo "$HEALTH_DISK_MOUNTS" | jq '[.[] | select(.mount == "/Volumes/Replays")] | length')
  [ "$count" -gt "0" ] && echo "true" || echo "false"
}
