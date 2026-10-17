#!/bin/sh
set -eu

PROXY_SCRIPT="/workspace/feature_extraction_v3/scripts/rstudio-48787-proxy.py"
PID_FILE="/tmp/feature-extraction-v3-rstudio-48787-proxy.pid"
LOG_FILE="/tmp/feature-extraction-v3-rstudio-48787-proxy.log"
START_STOP_DAEMON="/usr/sbin/start-stop-daemon"
PYTHON="/usr/bin/python3"

is_running() {
  "$START_STOP_DAEMON" --status --pidfile "$PID_FILE" --exec "$PYTHON" >/dev/null 2>&1
}

case "${1:-status}" in
  start)
    if is_running; then
      echo "rstudio-48787-proxy is already running"
      exit 0
    fi
    if [ -e "$PID_FILE" ]; then
      rm -f "$PID_FILE"
    fi
    "$START_STOP_DAEMON" \
      --start \
      --background \
      --make-pidfile \
      --pidfile "$PID_FILE" \
      --output "$LOG_FILE" \
      --chdir /workspace/feature_extraction_v3 \
      --startas "$PYTHON" \
      -- "$PROXY_SCRIPT"
    echo "rstudio-48787-proxy start requested"
    ;;
  status)
    if is_running; then
      echo "rstudio-48787-proxy is running (PID $(tr -d '\n' <"$PID_FILE"))"
    else
      echo "rstudio-48787-proxy is stopped"
      exit 1
    fi
    ;;
  stop)
    "$START_STOP_DAEMON" \
      --stop \
      --oknodo \
      --retry TERM/5/KILL/1 \
      --remove-pidfile \
      --pidfile "$PID_FILE" \
      --exec "$PYTHON"
    echo "rstudio-48787-proxy is stopped"
    ;;
  *)
    echo "Usage: $0 {start|status|stop}" >&2
    exit 2
    ;;
esac
