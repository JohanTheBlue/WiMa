#!/usr/bin/env bash
# scripts/wardrive.sh
set -euo pipefail

CMD="${1:-}"
IFACE="${2:-wlan1}"                  # interface is the SECOND arg
USER="$(whoami)"
BASE_DIR="${HOME}/wardrive"
LOGDIR="${BASE_DIR}/logs/kismet/wardrive"
PIDFILE="${LOGDIR}/kismet.pid"
RUNSTAMP="$(date +%Y%m%d-%H%M%S)"
OUTLOG="${LOGDIR}/kismet_run_${RUNSTAMP}.log"

ensure_dirs() {
  mkdir -p "${LOGDIR}"
  # make sure we can write
  touch "${LOGDIR}/.__wtest" 2>/dev/null || {
    echo "[!] Cannot write to ${LOGDIR}. Check permissions." >&2
    exit 1
  }
  rm -f "${LOGDIR}/.__wtest"
  chown -R "${USER}:${USER}" "${BASE_DIR}" || true
}

start_gpsd() {
  echo "[+] Ensuring gpsd is running..."
  sudo systemctl enable --now gpsd
  sleep 1
  sudo systemctl is-active --quiet gpsd || {
    echo "[!] gpsd is not active. Check gps device and gpsd.conf" >&2
    exit 1
  }
}

start_kismet() {
  # refuse to start if any kismet is running (service or user)
  if pgrep -f '^kismet($| )' >/dev/null || pgrep -f 'kismet_cap_linux_wifi' >/dev/null; then
    echo "[!] Another Kismet is already running. Run '$0 stop' first." >&2
    exit 1
  fi

  echo "[+] Bringing up ${IFACE} (ok if already up)"
  sudo ip link set "${IFACE}" up || true
  
  wait_for_gps_lock 30 || true
  echo "[+] Starting Kismet (headless). Logs -> ${LOGDIR}"

  echo "[+] Starting Kismet (headless). Logs -> ${LOGDIR}"
  nohup kismet --no-ncurses --nohttpd --use-gpsd \
    --log-prefix "${LOGDIR}" \
    --log-name   "wardrive" \
    --log-types  "kismet,netxml" \
    > "${OUTLOG}" 2>&1 &

  echo $! > "${PIDFILE}"
  echo "[+] Kismet started (pid $(cat "${PIDFILE}"))."
  echo "[+] Tail logs: tail -f '${OUTLOG}'"
}

wait_for_gps_lock() {
  local timeout="${1:-180}" t=0
  echo "[+] Waiting for GPS lock (up to ${timeout}s)..."
  while (( t < timeout )); do
    if gpspipe -w -n 5 2>/dev/null | jq -r 'select(.class=="TPV") | .mode' | grep -qE '^(2|3)$'; then
      echo "[+] GPS lock acquired."
      return 0
    fi
    sleep 1; ((t++))
  done
  echo "[!] No GPS lock after ${timeout}s; starting anyway."
  return 1
}


stop_kismet() {
  echo "[+] Stopping Kismet (service and user)..."
  sudo systemctl stop kismet 2>/dev/null || true

  # Kill helpers first
  sudo pkill -f kismet_cap_linux_wifi 2>/dev/null || true

  # Kill the PID we started, if present
  if [[ -f "${PIDFILE}" ]]; then
    pid="$(cat "${PIDFILE}")"
    sudo kill -TERM "${pid}" 2>/dev/null || true
    sleep 0.5
    sudo kill -KILL "${pid}" 2>/dev/null || true
    rm -f "${PIDFILE}" || true
  fi

  # Catch any strays (root/user, any path)
  sudo pkill -f '^kismet($| )' 2>/dev/null || true

  # Free ports just in case
  sudo fuser -k 2501/tcp 3501/tcp 2>/dev/null || true

  # Wait a moment for cleanup
  for _ in {1..10}; do
    pgrep -f '^kismet($| )' >/dev/null || break
    sleep 0.2
  done

  # Return iface to NetworkManager if present
  command -v nmcli >/dev/null 2>&1 && nmcli device set "${IFACE}" managed true || true

  echo "[+] Done. $(pgrep -fa kismet || echo 'No Kismet processes running.')"
}



status_kismet() {
  if [[ -f "${PIDFILE}" ]]; then
    pid="$(cat "${PIDFILE}")"
    if ps -p "${pid}" >/dev/null 2>&1; then
      echo "Kismet pid: ${pid}"
      ps -p "${pid}" -o pid,cmd --no-headers
      exit 0
    fi
  fi
  echo "Not started by this script."
}

case "${CMD}" in
  start)
    ensure_dirs
    start_gpsd
    start_kismet
    ;;
  stop)
    stop_kismet
    ;;
  status)
    status_kismet
    ;;
  *)
    echo "Usage: $0 start|stop|status [iface]" >&2
    exit 2
    ;;
esac
