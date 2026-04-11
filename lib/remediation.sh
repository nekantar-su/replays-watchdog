#!/bin/bash
# remediation.sh — reboot escalation only
# Camera and service restart logic removed. The Replays Service manages its own
# recovery via KeepAlive and internal restart. The watchdog only reboots as a
# last resort after 30 minutes of service unreachability (if allowReboot: true).
# Reboot is forked inline in watchdog.sh — no functions needed here.
