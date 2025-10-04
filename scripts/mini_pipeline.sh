#!/usr/bin/env bash
set -euo pipefail

# --- Prelude ---------------------------------------------------------------
BASE_DIR="$(pwd)"
LOGDIR="${BASE_DIR}/_mini/logs"
DATADIR="${BASE_DIR}/_mini/data"
mkdir -p "${LOGDIR}" "${DATADIR}"
PRIMARY_GJ="${LOGDIR}/networks_fixed.geojson"
ACCUM_GJ="${LOGDIR}/networks_fixed.geojson.prev"
FALLBACK_GJ="${LOGDIR}/networks_geojson_fallback.geojson"
CSV_OUT="${LOGDIR}/networks.csv"
DEV_JSON="${LOGDIR}/devices.json"
OUT_HTML="${LOGDIR}/networks_colored.html"
DB="${LOGDIR}/dummy.kismet"  # fake path

export PRIMARY_GJ ACCUM_GJ CSV_OUT DEV_JSON FALLBACK_GJ OUT_HTML

echo '{"type":"FeatureCollection","features":[]}' > "${PRIMARY_GJ}"

# --- Fake devices.json (no GPS) --------------------------------------------
cat > "${DEV_JSON}" <<'JSON'
[
  {"kismet.device.base":{"macaddr":"AA:BB:CC:DD:EE:01"},
   "kismet.device.base.type":"Wi-Fi AP"},
  {"kismet.device.base":{"macaddr":"AA:BB:CC:DD:EE:02"},
   "kismet.device.base.type":"Wi-Fi AP"}
]
JSON

# --- No-GPS detector --------------------------------------------------------
NO_GPS_RUN=false
GPS_COUNT="$(
python3 - <<'PY'
import json, os, sys
from pathlib import Path
p = Path(os.environ["DEV_JSON"])
n = 0
if p.exists():
  try:
    D = json.loads(p.read_text(encoding='utf-8'))
    for d in (D if isinstance(D, list) else []):
      loc = (d.get("kismet.device.base.location") or {})
      if loc.get("kismet.common.location.lat") is not None: n += 1
  except Exception:
    pass
print(n)
PY
)"
[[ "${GPS_COUNT}" -eq 0 ]] && { NO_GPS_RUN=true; echo "[NoGPS] Detected (0 devices with coords) — skipping CSV."; }

# --- CSV atomic (simulated; we won’t create TMP_GJ) -------------------------
if [[ "${NO_GPS_RUN}" != true ]]; then
  echo "[CSV] would run here"
else
  echo "[CSV] skipped"
fi

# --- AP inference (uses accumulator coords) ---------------------------------
# create a previous accumulator with last-known coords for one AP
cat > "${ACCUM_GJ}" <<'JSON'
{"type":"FeatureCollection","features":[
  {"type":"Feature","geometry":{"type":"Point","coordinates":[19.040,47.497]},
   "properties":{"Type":"AP","BSSID":"aa:bb:cc:dd:ee:01","SSID":"PrevSSID","Inferred":false}}
]}
JSON

python3 - <<'PY'
import json, os
from pathlib import Path
curr_gj = Path(os.environ["PRIMARY_GJ"])
prev_gj = Path(os.environ["ACCUM_GJ"])
dev_path = Path(os.environ["DEV_JSON"])

def load_fc(p):
    if not p.exists(): return {"type":"FeatureCollection","features":[]}
    try: return json.loads(p.read_text(encoding="utf-8"))
    except Exception: return {"type":"FeatureCollection","features":[]}

curr = load_fc(curr_gj); prev = load_fc(prev_gj)
prev_idx = {}
for f in prev.get("features", []):
    p = f.get("properties") or {}
    b = (p.get("BSSID") or p.get("MAC") or "").lower()
    if not b: continue
    try: lon, lat = f["geometry"]["coordinates"][:2]
    except Exception: continue
    prev_idx[b] = (float(lon), float(lat), p)

have_today = set()
for f in curr.get("features", []):
    p = f.get("properties") or {}
    b = (p.get("BSSID") or p.get("MAC") or "").lower()
    if b: have_today.add(b)

try: devices = json.loads(dev_path.read_text(encoding="utf-8"))
except Exception: devices = []

added = 0
for d in devices:
    if d.get("kismet.device.base.type","") != "Wi-Fi AP": continue
    bssid = (d.get("kismet.device.base",{}).get("macaddr") or "").lower()
    if not bssid or bssid in have_today: continue
    prev_hit = prev_idx.get(bssid)
    if not prev_hit: continue
    lon, lat, pprops = prev_hit
    curr["features"].append({
        "type":"Feature","geometry":{"type":"Point","coordinates":[lon,lat]},
        "properties":{"Type":"AP","BSSID":bssid,"Inferred":True}
    })
    added += 1

curr_gj.write_text(json.dumps(curr, ensure_ascii=False, indent=2), encoding="utf-8")
print(f"[NoGPS] Inferred APs from previous runs: {added}")
PY

# --- MergeRuns ---------------------------------------------------------------
python3 - <<'PY'
import json, os
from pathlib import Path

pg = Path(os.environ["PRIMARY_GJ"])
acc = Path(os.environ["ACCUM_GJ"])

def load_fc(p):
    if not p.exists(): return {"type":"FeatureCollection","features":[]}
    try: return json.loads(p.read_text(encoding="utf-8"))
    except Exception: return {"type":"FeatureCollection","features":[]}

prev = load_fc(acc).get("features", [])
curr = load_fc(pg).get("features", [])

def key(f):
    p=f.get("properties") or {}
    t=(p.get("Type") or "").lower()
    mac=(p.get("BSSID") or p.get("MAC") or "").lower()
    if t=="ap" and mac: return ("ap",mac)
    if mac: return ("dev",mac)
    try:
        lon,lat=f["geometry"]["coordinates"][:2]
        return ("xy", round(float(lon),6), round(float(lat),6))
    except: return ("id", id(f))

seen=set(); merged=[]; added=0
for f in prev:
    k=key(f)
    if k in seen: continue
    seen.add(k); merged.append(f)

for f in curr:
    k=key(f)
    if k in seen: continue
    seen.add(k); merged.append(f); added+=1

acc.write_text(json.dumps({"type":"FeatureCollection","features":merged}, ensure_ascii=False, indent=2), encoding="utf-8")
print(f"[MergeRuns] prev={len(prev)} new={len(curr)} -> merged={len(merged)} (added {added})")
PY

# --- Choose source = .prev + count ------------------------------------------
SRC_GJ="${ACCUM_GJ}"
CNT="$(jq -r '(.features|length)//0' "${SRC_GJ}")"
echo "[Counts] accumulated=${CNT}"
echo "OK"
