#!/bin/bash
# config.sh — load watchdog config and service config

WATCHDOG_CONFIG_PATH="$HOME/.replays-service/watchdog-config.json"
SERVER_JSON_PATH="$HOME/.replays-service/server.json"
RS_DATA_DIR="$HOME/.replays-service"
RS_LOG_DIR="$RS_DATA_DIR/log"
WATCHDOG_STATE_PATH="$RS_DATA_DIR/watchdog-state.json"
WATCHDOG_LOG="$RS_LOG_DIR/watchdog.log"
HEALTH_URL="http://localhost:4000/health"
HEALTH_TIMEOUT=10

load_config() {
  if [ ! -f "$WATCHDOG_CONFIG_PATH" ]; then
    echo "ERROR: watchdog config not found at $WATCHDOG_CONFIG_PATH" >&2
    exit 1
  fi

  SLACK_BOT_TOKEN=$(jq -r '.slackBotToken' "$WATCHDOG_CONFIG_PATH")
  SLACK_ACTIVE_CHANNEL=$(jq -r '.slackActiveChannelId' "$WATCHDOG_CONFIG_PATH")
  SLACK_LOG_CHANNEL=$(jq -r '.slackLogChannelId' "$WATCHDOG_CONFIG_PATH")
  SLACK_DIGEST_CHANNEL=$(jq -r '.slackDigestChannelId' "$WATCHDOG_CONFIG_PATH")
  UPTIME_ROBOT_HEARTBEAT_URL=$(jq -r '.heartbeatUrl // .uptimeRobotHeartbeatUrl // empty' "$WATCHDOG_CONFIG_PATH")

  THRESHOLD_CPU=$(jq -r '.thresholds.cpuPercent' "$WATCHDOG_CONFIG_PATH")
  THRESHOLD_CPU_CHECKS=$(jq -r '.thresholds.cpuSustainedChecks' "$WATCHDOG_CONFIG_PATH")
  THRESHOLD_BOOT_DISK=$(jq -r '.thresholds.bootDiskPercent' "$WATCHDOG_CONFIG_PATH")
  THRESHOLD_BOOT_DISK_MIN_GB=$(jq -r '.thresholds.bootDiskMinGb' "$WATCHDOG_CONFIG_PATH")
  THRESHOLD_EXT_DISK=$(jq -r '.thresholds.externalDiskPercent' "$WATCHDOG_CONFIG_PATH")
  THRESHOLD_LOG_MB=$(jq -r '.thresholds.logMaxMb' "$WATCHDOG_CONFIG_PATH")
  PENDING_QUEUE_GROWTH_CHECKS=$(jq -r '.thresholds.pendingQueueGrowthChecks' "$WATCHDOG_CONFIG_PATH")
  IDLE_GRACE_CHECKS=$(jq -r '.thresholds.idleGraceChecks' "$WATCHDOG_CONFIG_PATH")
  ALLOW_REBOOT=$(jq -r '.allowReboot // false' "$WATCHDOG_CONFIG_PATH")

  # Validate required config values
  local required_vars=(
    SLACK_BOT_TOKEN SLACK_ACTIVE_CHANNEL SLACK_LOG_CHANNEL SLACK_DIGEST_CHANNEL
    THRESHOLD_CPU THRESHOLD_CPU_CHECKS THRESHOLD_BOOT_DISK
    THRESHOLD_BOOT_DISK_MIN_GB THRESHOLD_EXT_DISK THRESHOLD_LOG_MB
    PENDING_QUEUE_GROWTH_CHECKS IDLE_GRACE_CHECKS
  )
  for var in "${required_vars[@]}"; do
    local val="${!var}"
    if [ -z "$val" ] || [ "$val" = "null" ]; then
      echo "ERROR: watchdog-config.json is missing required field for $var" >&2
      exit 1
    fi
  done
}

load_bearer_token() {
  if [ ! -f "$SERVER_JSON_PATH" ]; then
    echo ""
    return
  fi
  jq -r '.accessToken // empty' "$SERVER_JSON_PATH" 2>/dev/null || echo ""
}

load_tenant_code() {
  if [ ! -f "$SERVER_JSON_PATH" ]; then
    echo "unknown"
    return
  fi
  jq -r '.tenantCode // "unknown"' "$SERVER_JSON_PATH" 2>/dev/null || echo "unknown"
}
