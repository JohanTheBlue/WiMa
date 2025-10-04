# scripts/wardrive.sh  (fixed)
#!/usr/bin/env bash
set -euo pipefail

CMD="${1:-}"
IFACE="${2:-wlan1}"          # <-- interface is the SECOND arg now
USER="$(whoami)"
BASE_DIR="${HOME}/wardrive"
LOGDIR="${BASE_DIR}/logs/kismet/wardrive"
PIDFILE="${LOGDIR}/kismet.pid"
OUTLOG="${LOGDIR}/kismet_run_$(date +%Y%m%d-%H%M%S).log"

ensure_dirs(){ mkdir -p "${LOGDIR}"; chown -R "${USER}:${USER}" "${BASE_DIR}" || true; }
start_gpsd(){ sudo systemctl enable --now gpsd; sleep 1; sudo systemctl status --no-pager gpsd | sed -n '1,6p'; }
start_kismet(){
  echo "[+] Starting Kismet (headless). Logs -> ${LOGDIR}"
  sudo ip link set "${IFACE}" up || true
  nohup kismet --no-ncurses \
    --log-types=kismet,netxml \
    --log-prefix "${LOGDIR}/wardrive" > "${OUTLOG}" 2>&1 &
  echo $! > "${PIDFILE}"
  echo "[+] Kismet started (pid $(cat "${PIDFILE}")). Tail: tail -f ${OUTLOG}"
}
stop_kismet(){
  if [[ -f "${PIDFILE}" ]]; then
    pid="$(cat "${PIDFILE}")"
    echo "[+] Stopping Kismet pid ${pid}..."
    kill "${pid}" 2>/dev/null || true
    rm -f "${PIDFILE}"
    sleep 1
  else
    echo "[!] No pidfile; if needed: pkill kismet"
  fi
}

case "${CMD}" in
  start) ensure_dirs; start_gpsd; start_kismet ;;
  stop)  stop_kismet ;;
  status)
    [[ -f "${PIDFILE}" ]] && { echo "Kismet pid: $(cat "${PIDFILE}")"; ps -p "$(cat "${PIDFILE}")" -o pid,cmd --no-headers || true; } \
                           || echo "Not started by this script."
    ;;
  *) echo "Usage: $0 start|stop|status [iface]"; exit 2;;
esac
