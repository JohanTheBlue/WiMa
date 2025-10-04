#!/usr/bin/env bash
# scripts/export.sh
# Usage: ./export.sh
# Finds the newest .kismet DB under logs/kismet/wardrive, exports:
#  - devices.json (kismetdb_dump_devices)
#  - networks.csv (kismetdb_to_wiglecsv)
#  - networks.geojson (jq transform)
#  - networks.kml (kismetdb_to_kml)
#  - networks.html (folium map via make_map.py)
#
# Assumes kismet-logtools and jq are installed, and you have a venv at ~/scapy-venv
# Adjust paths/venv as needed.

set -euo pipefail

BASE_DIR="${HOME}/wardrive"
LOGDIR="${BASE_DIR}/logs/kismet/wardrive"
VENV="${HOME}/scapy-venv"
MAP_SCRIPT="${HOME}/make_map.py"

if [[ ! -d "${LOGDIR}" ]]; then
  echo "Logdir ${LOGDIR} not found. Run capture first."
  exit 1
fi

# pick the newest .kismet file
KISMET_DB="$(ls -1t ${LOGDIR}/*.kismet 2>/dev/null | head -n1 || true)"
if [[ -z "${KISMET_DB}" ]]; then
  echo "No .kismet files found in ${LOGDIR}"
  exit 1
fi

echo "[*] Using DB: ${KISMET_DB}"

# outputs
DEV_JSON="${LOGDIR}/devices.json"
WIGLE_CSV="${LOGDIR}/networks.csv"
GEOJSON="${LOGDIR}/networks.geojson"
KML="${LOGDIR}/networks.kml"
HTML="${LOGDIR}/networks.html"

# overwrite exports
/usr/bin/kismetdb_dump_devices --in "${KISMET_DB}" --out "${DEV_JSON}" --force
/usr/bin/kismetdb_to_wiglecsv --in "${KISMET_DB}" --out "${WIGLE_CSV}" --force || true
/usr/bin/kismetdb_to_kml --in "${KISMET_DB}" --out "${KML}" --force || true

# build geojson from devices.json (coalesce avg_* and last_*)
jq -c '
  .[]
  | .kismet.device.base as $b
  | ($b.location.avg_lat // $b.location.last_lat) as $lat
  | ($b.location.avg_lon // $b.location.last_lon) as $lon
  | select($lat != null and $lon != null)
  | {
      type:"Feature",
      geometry:{ type:"Point", coordinates:[ $lon, $lat ] },
      properties:{
        SSID:   ($b.name    // "hidden"),
        BSSID:  ($b.macaddr // ""),
        Type:   ($b.type    // ""),
        Channel:($b.channel // ""),
        Signal: ($b.signal.last // null)
      }
    }' "${DEV_JSON}" \
| jq -s '{ type:"FeatureCollection", features:. }' > "${GEOJSON}"


echo "[*] Exports written:"
ls -lh "${DEV_JSON}" "${WIGLE_CSV}" "${GEOJSON}" "${KML}" || true

# create HTML map using venv python
if [[ -f "${MAP_SCRIPT}" ]]; then
  if [[ -d "${VENV}" ]]; then
    source "${VENV}/bin/activate"
  fi
  python "${MAP_SCRIPT}" "${GEOJSON}" "${HTML}"
  echo "[*] Map created: ${HTML}"
else
  echo "[!] Map script not found at ${MAP_SCRIPT} — skip map generation."
fi

echo "[+] Done."
