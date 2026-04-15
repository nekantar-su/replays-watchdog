#!/bin/bash
# diagnostics.sh — collect incident diagnostic snapshots

DIAG_DIR="$RS_DATA_DIR/diagnostics"

collect_tier1() {
  local tenant="$1"
  local issue_summary="$2"   # comma-separated list of all active issues
  local failures_file="${3:-}"

  local timestamp
  timestamp=$(date '+%Y%m%d-%H%M%S')

  mkdir -p "$DIAG_DIR"

  # Keep only the 10 most recent diagnostic files
  local file_count
  file_count=$(ls "$DIAG_DIR"/incident-*.txt 2>/dev/null | wc -l | tr -d ' ')
  if [ "$file_count" -ge 10 ]; then
    ls -t "$DIAG_DIR"/incident-*.txt 2>/dev/null | tail -n +10 | xargs rm -f 2>/dev/null || true
  fi

  local outfile="$DIAG_DIR/incident-${timestamp}.txt"

  {
    echo "================================================================"
    echo "  INCIDENT REPORT — ${tenant}"
    echo "================================================================"
    echo "  Issues:      ${issue_summary}"
    echo "  Generated:   $(date '+%a %b %-d, %Y at %-I:%M:%S %p')"
    echo "  Host:        $(hostname)"
    echo "  Mac uptime:  $(uptime | sed 's/^.*up /up /' | sed 's/,.*//')"
    echo "================================================================"
    echo ""

    # ── Active Issues ──────────────────────────────────────────────────
    if [ -n "$failures_file" ] && [ -f "$failures_file" ]; then
      echo "--- ACTIVE ISSUES -------------------------------------------"
      while IFS='|' read -r key detail; do
        echo "  • $key — $detail"
      done < "$failures_file"
      echo ""
    fi

    # ── System Resources ───────────────────────────────────────────────
    echo "--- SYSTEM RESOURCES ----------------------------------------"
    local top_out
    top_out=$(top -l 1 -n 0 2>/dev/null)
    local cpu_line mem_line
    cpu_line=$(echo "$top_out" | grep "CPU usage" || echo "  (unavailable)")
    mem_line=$(echo "$top_out"  | grep "PhysMem"   || echo "  (unavailable)")
    echo "  CPU:    $cpu_line"
    echo "  RAM:    $mem_line"
    echo "  Load:   $(uptime | awk -F'load averages:' '{print $2}' | xargs)"
    echo ""

    # ── Storage ────────────────────────────────────────────────────────
    echo "--- STORAGE -------------------------------------------------"
    if [ -d "/Volumes/Replays" ]; then
      echo "  External SSD:  MOUNTED ✓"
    else
      echo "  External SSD:  NOT MOUNTED ✗  (/Volumes/Replays missing)"
      echo "  NOTE: Recording may be falling back to boot drive or failing entirely"
    fi
    echo ""
    df -h / /Volumes/Replays 2>/dev/null | sed 's/^/  /' || df -h / 2>/dev/null | sed 's/^/  /'
    echo ""

    # ── Service Status ─────────────────────────────────────────────────
    echo "--- SERVICE STATUS ------------------------------------------"
    if [ -n "${HEALTH_JSON:-}" ]; then
      local status cameras_up cameras_total uptime mem
      status=$(echo "$HEALTH_JSON"        | jq -r '.status // "unknown"')
      cameras_total=$(echo "$HEALTH_JSON" | jq '[.cameras // [] | .[]] | length')
      cameras_up=$(echo "$HEALTH_JSON"    | jq '[.cameras // [] | .[] | select(.isRunning==true and .isHealthy==true)] | length')
      uptime=$(echo "$HEALTH_JSON"        | jq -r '.uptimeSeconds // "unknown"')
      mem=$(echo "$HEALTH_JSON"           | jq -r '.memoryStatus // "unknown"')
      echo "  Status:          $status"
      echo "  Cameras healthy: ${cameras_up}/${cameras_total}"
      echo "  Service uptime:  ${uptime}s"
      echo "  Memory status:   $mem"
      echo ""
      echo "  Full /health response:"
      echo "$HEALTH_JSON" | jq '.' | sed 's/^/    /'
    else
      echo "  UNREACHABLE — http://localhost:4000/health did not respond"
    fi
    echo ""

    # ── Camera Status ──────────────────────────────────────────────────
    echo "--- CAMERA STATUS (from health endpoint) --------------------"
    if [ -n "${HEALTH_JSON:-}" ] && echo "$HEALTH_JSON" | jq -e '.cameras' &>/dev/null; then
      echo "$HEALTH_JSON" | jq -r '
        .cameras // [] | .[] |
        "  \(.name // .id // "?"): running=\(.isRunning) healthy=\(.isHealthy) pending=\(.pendingChunks // "?")"
      ' 2>/dev/null || echo "  (could not parse cameras)"
    else
      echo "  (service unreachable — no live camera data)"
    fi
    echo ""

    # ── RTSP Reachability ──────────────────────────────────────────────
    echo "--- RTSP STREAM REACHABILITY (TCP port 554) -----------------"
    echo "  ✓ reachable  = camera is on the network and responding"
    echo "  ✗ UNREACHABLE = camera is offline, unplugged, or wrong IP"
    if [ -z "${HEALTH_JSON:-}" ]; then
      echo ""
      echo "  ⚠️  NOTE: Service was unreachable when this diagnostic was captured."
      echo "  RTSP results below may be unreliable — Mac Mini may have been under"
      echo "  I/O stress (e.g. SSD write timeout). Verify cameras independently."
    fi
    echo ""
    local server_json="$RS_DATA_DIR/server.json"
    if [ -f "$server_json" ]; then
      local cam_count
      cam_count=$(jq '.cameras | length' "$server_json" 2>/dev/null || echo "?")
      echo "  Cameras configured: $cam_count"
      echo ""
      jq -r '.cameras[] | select(.isEnabled == true) | "\(.id)|\(.feed)|\(.videoCodec // "?")|\(.audioCodec // "?")"' \
        "$server_json" 2>/dev/null | \
      while IFS='|' read -r cam_id feed_url video_codec audio_codec; do
        local host port tcp_status
        host=$(echo "$feed_url" | sed -E 's|rtsp://[^@]*@([^:/]+).*|\1|')
        port=$(echo "$feed_url" | sed -E 's|rtsp://[^@]*@[^:]+:([0-9]+).*|\1|')
        [ -z "$port" ] && port=554
        if nc -z -w 3 "$host" "$port" 2>/dev/null; then
          tcp_status="✓ reachable"
        else
          tcp_status="✗ UNREACHABLE"
        fi
        printf "  %-25s %-16s %s  [video=%s audio=%s]\n" \
          "$cam_id" "$tcp_status" "$host:$port" "$video_codec" "$audio_codec"
        echo "    feed: $feed_url"
      done
    else
      echo "  server.json not found — cannot check RTSP feeds"
    fi
    echo ""

    # ── Mediamtx (internal RTSP proxy) ────────────────────────────────
    echo "--- MEDIAMTX (internal RTSP proxy) --------------------------"
    local mediamtx_pids
    mediamtx_pids=$(pgrep -x mediamtx 2>/dev/null || echo "")
    if [ -n "$mediamtx_pids" ]; then
      echo "  mediamtx: RUNNING (PID $mediamtx_pids)"
      lsof -iTCP:8554 -sTCP:LISTEN 2>/dev/null | grep mediamtx | sed 's/^/  /' || \
        echo "  (not listening on 8554 — may use different port)"
    else
      echo "  mediamtx: NOT RUNNING ✗"
      echo "  NOTE: If mediamtx is dead, cameras cannot stream regardless of RTSP reachability"
    fi
    local gst_count
    gst_count=$(pgrep -x gst-launch-1.0 2>/dev/null | wc -l | tr -d ' ')
    echo "  Active gst-launch pipelines: $gst_count"
    echo ""

    # ── Network ────────────────────────────────────────────────────────
    echo "--- NETWORK -------------------------------------------------"
    local internet_status gcp_status
    if nc -z -w 3 8.8.8.8 53 2>/dev/null; then
      internet_status="✓ reachable"
    else
      internet_status="✗ UNREACHABLE"
    fi
    if nc -z -w 3 storage.googleapis.com 443 2>/dev/null; then
      gcp_status="✓ reachable"
    else
      gcp_status="✗ UNREACHABLE"
    fi
    echo "  Internet (8.8.8.8:53):           $internet_status"
    echo "  GCP Storage (port 443):          $gcp_status"
    echo ""

    # ── Processes ──────────────────────────────────────────────────────
    echo "--- SERVICE PROCESSES ---------------------------------------"
    ps -A -o pid,pcpu,pmem,comm | grep -E "replays-service|mediamtx|gst-launch|ffmpeg|bun" 2>/dev/null \
      | sed 's/^/  /' || echo "  (none found)"
    echo ""

    echo "--- TOP SYSTEM PROCESSES (by CPU) ---------------------------"
    ps -A -o pid,pcpu,pmem,comm -r 2>/dev/null | head -12 | sed 's/^/  /'
    echo ""

    # ── Logs ───────────────────────────────────────────────────────────
    echo "--- SERVICE LOG (last 60 lines) -----------------------------"
    local svc_log="$RS_LOG_DIR/replays-service-launchd.log"
    if [ -f "$svc_log" ]; then
      tail -60 "$svc_log" | sed 's/^/  /'
    else
      echo "  (log not found: $svc_log)"
    fi
    echo ""

    echo "--- WATCHDOG LOG (last 30 lines) ----------------------------"
    if [ -f "$WATCHDOG_LOG" ]; then
      tail -30 "$WATCHDOG_LOG" | sed 's/^/  /'
    else
      echo "  (watchdog log not found)"
    fi
    echo ""

    # ── LaunchAgent ────────────────────────────────────────────────────
    echo "--- LAUNCHAGENT STATUS --------------------------------------"
    launchctl list | grep -E "com.podplay|replays" 2>/dev/null | sed 's/^/  /' || echo "  (none found)"
    echo ""

    echo "================================================================"
    echo "  Full report (with credentials): $outfile"
    echo "  Retrieve: scp $(whoami)@<IP>:$outfile ./incident-report.txt"
    echo "================================================================"

  } > "$outfile"

  echo "$outfile"
}
