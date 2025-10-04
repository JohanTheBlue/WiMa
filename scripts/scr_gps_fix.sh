#!/usr/bin/env bash
# scr_gps_fix.sh — Diagnose & fix Pi 3B+ + NEO-M8M (u-blox) GPS + gpsd
# Usage:
#   sudo ./scr_gps_fix.sh              # diagnose, no destructive changes
#   sudo ./scr_gps_fix.sh --fix        # also patch gpsd config & UART settings (safe)
#   sudo ./scr_gps_fix.sh --set-9600   # stop gpsd, talk UBX, set 9600/1Hz, save
set -euo pipefail

SERIAL_DEV="/dev/serial0"
[[ -e "$SERIAL_DEV" ]] || SERIAL_DEV="/dev/ttyAMA0"
[[ -e "$SERIAL_DEV" ]] || SERIAL_DEV="/dev/ttyS0"

sed -i "s|^DEVICES=.*|DEVICES=\"${SERIAL_DEV}\"|" /etc/default/gpsd || echo "DEVICES=\"${SERIAL_DEV}}\"" | sudo tee -a /etc/default/gpsd
sed -i 's|^GPSD_OPTIONS=.*|GPSD_OPTIONS="-n"|' /etc/default/gpsd || echo 'GPSD_OPTIONS="-n"' | sudo tee -a /etc/default/gpsd

if ! systemctl start gpsd.socket; then
  mkdir -p /etc/systemd/system/gpsd.socket.d
  cat >/etc/systemd/system/gpsd.socket.d/override.conf <<'OVR'
[Socket]
ListenStream=
ListenDatagram=
ListenNetlink=
ListenStream=/var/run/gpsd.sock
OVR
  systemctl daemon-reload
  systemctl restart gpsd.socket
fi


# -------- Options --------
DO_FIX=0
DO_SET9600=0
for a in "$@"; do
  case "$a" in
    --fix) DO_FIX=1 ;;
    --set-9600) DO_FIX=1; DO_SET9600=1 ;;
    -h|--help) echo "Usage: sudo $0 [--fix] [--set-9600]"; exit 0 ;;
    *) echo "Unknown arg: $a" >&2; exit 2 ;;
  esac
done

# -------- Consts --------
DEFAULTS_FILE="/etc/default/gpsd"
BOOT_CONFIG="/boot/config.txt"
CMDLINE="/boot/cmdline.txt"
GPSD_SOCK="/var/run/gpsd.sock"
REQUIRED=(gpsd gpspipe cgps ubxtool stty sed awk cut tr tee systemctl udevadm)

# -------- UI --------
log(){ echo -e "\e[36m[*]\e[0m $*"; }
ok(){  echo -e "\e[32m[✓]\e[0m $*"; }
warn(){ echo -e "\e[33m[!]\e[0m $*"; }
err(){ echo -e "\e[31m[✗]\e[0m $*"; }

# -------- Helpers --------
need_root(){ [[ $EUID -eq 0 ]] || { err "Run as root (sudo)"; exit 1; }; }
have(){ command -v "$1" >/dev/null 2>&1; }
backup(){ [[ -f "$1" ]] && cp -a "$1" "$1.bak.$(date +%Y%m%d%H%M%S)" || true; }

resolve_serial(){
  # Prefer serial0 symlink if present; else fall back to AMA0 then S0
  local dev=""
  [[ -e /dev/serial0 ]] && dev="/dev/serial0"
  [[ -z "$dev" && -e /dev/ttyAMA0 ]] && dev="/dev/ttyAMA0"
  [[ -z "$dev" && -e /dev/ttyS0   ]] && dev="/dev/ttyS0"
  echo "$dev"
}

serial_target(){
  # If /dev/serial0 exists, show where it points; else echo same path
  local path="$1"
  if [[ "$path" == "/dev/serial0" && -L /dev/serial0 ]]; then
    readlink -f /dev/serial0
  else
    echo "$path"
  fi
}

# -------- Preflight --------
need_root
for c in "${REQUIRED[@]}"; do
  have "$c" || { err "Missing $c (apt install gpsd gpsd-clients gpsd-tools pps-tools)"; exit 1; }
done

# -------- UART present? --------
SER="$(resolve_serial)"
if [[ -z "$SER" ]]; then
  err "No serial device found (serial0/ttyAMA0/ttyS0). Enable UART and check wiring."
  if (( DO_FIX )); then
    backup "$BOOT_CONFIG"
    sed -i '/^enable_uart=/d' "$BOOT_CONFIG"
    echo 'enable_uart=1' >> "$BOOT_CONFIG"
    if ! grep -q '^dtoverlay=pi3-disable-bt' "$BOOT_CONFIG"; then
      echo 'dtoverlay=pi3-disable-bt' >> "$BOOT_CONFIG"
    fi
    backup "$CMDLINE"
    sed -i 's/\bconsole=\(serial0\|ttyAMA0\),[0-9]\+\b//g' "$CMDLINE"
    warn "Applied UART tweaks. Reboot needed."
  fi
  exit 1
fi
ok "UART device: $SER ($(serial_target "$SER"))"

# -------- gpsd.defaults sanity --------
if [[ -f "$DEFAULTS_FILE" ]]; then
  DEV_LINE="$(grep -E '^DEVICES=' "$DEFAULTS_FILE" || true)"
  OPT_LINE="$(grep -E '^GPSD_OPTIONS=' "$DEFAULTS_FILE" || true)"
  if (( DO_FIX )); then
    backup "$DEFAULTS_FILE"
    if [[ "$DEV_LINE" != *"$SER"* ]]; then
      sed -i "s|^DEVICES=.*|DEVICES=\"$SER\"|" "$DEFAULTS_FILE" || echo "DEVICES=\"$SER\"" >> "$DEFAULTS_FILE"
      ok "Set DEVICES=\"$SER\" in $DEFAULTS_FILE"
    else
      ok "DEVICES already points to $SER"
    fi
    if [[ "$OPT_LINE" != *"-n"* ]]; then
      sed -i 's|^GPSD_OPTIONS=.*|GPSD_OPTIONS="-n"|' "$DEFAULTS_FILE" || echo 'GPSD_OPTIONS="-n"' >> "$DEFAULTS_FILE"
      ok "Set GPSD_OPTIONS=\"-n\" in $DEFAULTS_FILE"
    else
      ok "GPSD_OPTIONS already -n"
    fi
  else
    ok "$DEFAULTS_FILE present."
  fi
else
  warn "$DEFAULTS_FILE missing; create with DEVICES=\"$SER\" and GPSD_OPTIONS=\"-n\" if needed."
fi

# -------- Stop gpsd if we plan to touch the device --------
if (( DO_SET9600 )); then
  log "Stopping gpsd to free $SER ..."
  systemctl stop gpsd || true
  systemctl stop gpsd.socket || true
  rm -f "$GPSD_SOCK" || true
fi

# -------- Optional: pin module to 9600/1Hz & save --------
if (( DO_SET9600 )); then
  log "Configuring NEO-M8M to 9600/1Hz (UBX+NMEA) ..."
  # Try at a few common bauds in case module is on a different rate
  for B in 9600 38400 115200; do
    if ubxtool -f "$SER" -s "$B" -p MON-VER >/dev/null 2>&1; then
      ok "UBX responded at $B"
      # Set UART1 to 9600
      ubxtool -f "$SER" -s "$B" -p CFG-PRT,0,0,0,0,9600 || true
      # Switch to 9600 for follow-ups
      ubxtool -f "$SER" -s 9600 -p CFG-RATE,1000,1 || true
      ubxtool -f "$SER" -s 9600 -e NMEA+UBX || true
      ubxtool -f "$SER" -s 9600 -p SAVE || true
      ok "Saved 9600/1Hz + UBX+NMEA"
      break
    fi
  done
fi

# -------- Start gpsd via socket (recommended) --------
log "Ensuring socket-activated gpsd ..."
systemctl disable --now gpsd.service >/dev/null 2>&1 || true

if ! systemctl start gpsd.socket; then
  warn "gpsd.socket failed to start. Port 2947 may be busy; switching to Unix-socket-only."
  mkdir -p /etc/systemd/system/gpsd.socket.d
  cat >/etc/systemd/system/gpsd.socket.d/override.conf <<'OVR'
[Socket]
ListenStream=
ListenDatagram=
ListenNetlink=
ListenStream=/var/run/gpsd.sock
OVR
  systemctl daemon-reload
  systemctl start gpsd.socket
fi


# -------- Live check via gpspipe --------
log "Polling gpsd for devices ..."
DEV_JSON="$(timeout 4s gpspipe -w -n 5 | awk '/"class":"DEVICES"/{print; exit}')"
if [[ -n "$DEV_JSON" ]]; then
  echo "$DEV_JSON" | sed -e 's/\\\//\//g' | cut -c1-200
else
  warn "No DEVICES yet; gpsd may still be starting."
fi

log "Quick NMEA/TPV smoke test (8s) ..."
HAS_NMEA=0; HAS_TPV=0
if timeout 8s gpspipe -r -n 40 | grep -q '^\$G[NP]'; then HAS_NMEA=1; fi
if timeout 8s gpspipe -w -n 40 | grep -q '"class":"TPV"'; then HAS_TPV=1; fi
[[ $HAS_NMEA -eq 1 ]] && ok "NMEA flowing from gpsd." || warn "No NMEA yet."
[[ $HAS_TPV -eq 1 ]] && ok "Got TPV JSON (may still be mode 1 if no sky)."

# -------- Summary --------
echo
ok "Done."
echo "Summary:"
echo "  - Device        : $SER -> $(serial_target "$SER")"
SOCK_ACTIVE=$(systemctl is-active gpsd.socket 2>/dev/null || echo inactive)
SRV_ACTIVE=$(systemctl is-active gpsd 2>/dev/null || echo inactive)
SRV_ENABLED=$(systemctl is-enabled gpsd 2>/dev/null || echo disabled)

echo "  - gpsd.socket   : ${SOCK_ACTIVE}"
echo "  - gpsd.service  : ${SRV_ACTIVE} (enabled=${SRV_ENABLED})"
echo "  - NMEA seen     : $([[ $HAS_NMEA -eq 1 ]] && echo yes || echo no)"
echo "  - TPV seen      : $([[ $HAS_TPV -eq 1 ]] && echo yes || echo no)"
echo
echo "Tips:"
echo "  - Use: cgps -s   and give it clear sky until mode=2/3."
echo "  - If you still rely on /dev/serial0, keep UART enabled in $BOOT_CONFIG and remove any serial console from $CMDLINE."
