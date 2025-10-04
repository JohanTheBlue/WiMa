#!/usr/bin/env bash
# scripts/build_map.sh — robust export + dual-color Leaflet map (with type enrichment)
#
# 1) Picks newest .kismet DB (or uses the one you pass)
# 2) CSV → GeoJSON (robust parser, handles Wigle preamble & RSSI)
# 3) Enriches Type from Kismet devices.json (AP/Client/Bridge)
# 4) Fallback: JSON dump → GeoJSON
# 5) Builds Leaflet HTML with toggle UI
# --- ONE prelude: paths + DB pick -------------------------------------------
set -euo pipefail

# --- Args --------------------------------------------------------------------
DRY_RUN=false
CI_CHECK=false
DB_ARG=""

# Parse flags first; first non-flag becomes DB_ARG (optional)
while (($#)); do
  case "$1" in
    --dry-run) DRY_RUN=true; shift ;;
    --ci-check) CI_CHECK=true; DRY_RUN=true; shift ;;
    --) shift; break ;;
    -*)  # unknown flag -> ignore for now
        shift ;;
    *)   # first positional -> DB path
        if [[ -z "$DB_ARG" ]]; then DB_ARG="$1"; fi
        shift ;;
  esac
done

# --- Prelude: paths, exports, DB pick ---------------------------------------
BASE_DIR="${HOME}/wardrive"
LOGDIR="${BASE_DIR}/logs/kismet/wardrive"
DATADIR="${BASE_DIR}/data"
mkdir -p "${LOGDIR}" "${DATADIR}"

PRIMARY_GJ="${LOGDIR}/networks_fixed.geojson"
ACCUM_GJ="${LOGDIR}/networks_fixed.geojson.prev"
FALLBACK_GJ="${LOGDIR}/networks_geojson_fallback.geojson"
CSV_OUT="${LOGDIR}/networks.csv"
DEV_JSON="${LOGDIR}/devices.json"
OUT_HTML="${LOGDIR}/networks_colored.html"

export PRIMARY_GJ ACCUM_GJ CSV_OUT DEV_JSON FALLBACK_GJ OUT_HTML DATADIR LOGDIR

# init today's file once
echo '{"type":"FeatureCollection","features":[]}' > "${PRIMARY_GJ}"

# Decide DB from DB_ARG or pick newest
if [[ -n "${DB_ARG}" ]]; then
  DB="${DB_ARG}"
else
  DB="$(ls -1t "${LOGDIR}"/wardrive-*.kismet 2>/dev/null | head -n1 || true)"
fi

# Make absolute & validate
if [[ -n "${DB:-}" ]]; then DB="$(readlink -f "${DB}")"; fi
if [[ -z "${DB:-}" || ! -r "${DB}" ]]; then
  echo "[!] No readable .kismet DB under ${LOGDIR}." >&2
  ls -lt "${LOGDIR}"/wardrive-*.kismet 2>/dev/null || echo "(none)" >&2
  exit 2
fi
export DB
echo "[*] Using DB: ${DB}"


# --- CI / preflight checks ----------------------------------------------------
ci_check() {
  echo "[CI] bash version: $BASH_VERSION"
  command -v kismetdb_dump_devices >/dev/null || { echo "[CI] Missing kismetdb_dump_devices"; return 1; }
  command -v jq >/dev/null || { echo "[CI] Missing jq"; return 1; }
  command -v python3 >/dev/null || { echo "[CI] Missing python3"; return 1; }
  [[ -r "${DB}" ]] || { echo "[CI] DB not readable: ${DB}"; return 1; }
  # Writable outputs
  touch "${PRIMARY_GJ}" "${FALLBACK_GJ}" "${CSV_OUT}" "${DEV_JSON}" 2>/dev/null || true
  for p in "${PRIMARY_GJ}" "${FALLBACK_GJ}" "${CSV_OUT}" "${DEV_JSON}"; do
    [[ -w "$p" || -w "$(dirname "$p")" ]] || { echo "[CI] Not writable: $p"; return 1; }
  done
  echo "[CI] OK"
  return 0
}

if [[ "${CI_CHECK}" == true ]]; then
  ci_check || exit 2
fi



# ---- devices.json dumper (single-shot + cached status) ----------------------
DUMP_STATUS=""   # "", "ok", or "fail"
run_dump_devices() {
  if [[ -n "${DUMP_STATUS}" ]]; then
    [[ "${DUMP_STATUS}" == "ok" ]] && { echo "[Dump] Already OK (cached)."; return 0; }
    echo "[Dump] Already failed earlier (cached)."; return 1
  fi

  echo "[Dump] Running kismetdb_dump_devices once..."
  # DO NOT hide stderr here; we want the error message
  if kismetdb_dump_devices --in "${DB}" --out "${DEV_JSON}" --force; then
    # make mtime definitely newer than DB (same-second granularity fix)
    if command -v date >/dev/null 2>&1; then
      db_ts=$(date -r "${DB}" +%s 2>/dev/null || echo 0)
      [[ "${db_ts}" != 0 ]] && touch -d "@$(( db_ts + 1 ))" "${DEV_JSON}" 2>/dev/null || true
    fi
    DUMP_STATUS="ok"
    echo "[Dump] devices.json updated."
    return 0
  else
    DUMP_STATUS="fail"
    echo "[!] kismetdb_dump_devices failed (see error above)."
    return 1
  fi
}

# Infer AP coords for APs with no GPS today, using last-known coords from the accumulator
python3 - <<'PY'
import json, os
from pathlib import Path

curr_gj = Path(os.environ["PRIMARY_GJ"])                  # today's geojson
prev_gj = Path(str(curr_gj).replace(".geojson",".geojson.prev"))  # accumulator from prior runs
dev_path = Path(os.environ.get("DEV_JSON",""))

def load_fc(p):
    if not p.exists() or p.stat().st_size == 0:
        return {"type":"FeatureCollection","features":[]}
    try:
        return json.loads(p.read_text(encoding="utf-8"))
    except Exception:
        return {"type":"FeatureCollection","features":[]}

curr = load_fc(curr_gj)
prev = load_fc(prev_gj)

# Index previous known AP locations: BSSID -> (lon, lat, props)
prev_idx = {}
for f in prev.get("features", []):
    props = f.get("properties", {}) or {}
    b = (props.get("BSSID") or props.get("MAC") or "").strip().lower()
    if not b: 
        continue
    try:
        lon, lat = f["geometry"]["coordinates"][:2]
        lon = float(lon); lat = float(lat)
    except Exception:
        continue
    prev_idx[b] = (lon, lat, props)

# BSSIDs already present today
have_today = set()
for f in curr.get("features", []):
    p = f.get("properties", {}) or {}
    b = (p.get("BSSID") or p.get("MAC") or "").strip().lower()
    if b: 
        have_today.add(b)

# Load devices.json to discover APs seen today (even if they lack GPS)
try:
    devices = json.loads(dev_path.read_text(encoding="utf-8")) if dev_path.exists() else []
except Exception:
    devices = []

added = 0
for d in devices:
    if d.get("kismet.device.base.type","") != "Wi-Fi AP":
        continue
    bssid = (d.get("kismet.device.base.macaddr") or "").strip().lower()
    if not bssid or bssid in have_today:
        continue
    prev_hit = prev_idx.get(bssid)
    if not prev_hit:
        continue  # never seen with GPS before
    lon, lat, pprops = prev_hit
    props = {
        "Type": "AP",
        "BSSID": bssid,
        "SSID": d.get("kismet.device.base.commonname") or pprops.get("SSID") or "",
        "Channel": d.get("kismet.device.base.channel") or pprops.get("Channel") or "",
        "Signal dBm": pprops.get("Signal dBm"),
        "Inferred": True,
        "Note": "ap_inferred_from_previous_run"
    }
    curr["features"].append({
        "type":"Feature",
        "geometry":{"type":"Point","coordinates":[lon,lat]},
        "properties": props
    })
    added += 1

curr_gj.write_text(json.dumps(curr, ensure_ascii=False, indent=2), encoding="utf-8")
print(f"[NoGPS] Inferred APs from previous runs: {added}")
PY

mkdir -p "${LOGDIR}" "${DATADIR}"

# Always dump devices so we can enrich + infer later
if ! run_dump_devices; then
  echo "[!] kismetdb_dump_devices failed; proceeding without type enrichment." >&2
fi

# Clean CSV/fallback only (do NOT delete PRIMARY_GJ again)
rm -f "${CSV_OUT}" "${FALLBACK_GJ}" 2>/dev/null || true

CSV_OK=false

# --- Prefer native GeoJSON if available (keeps real types) -------------------
if command -v kismetdb_to_geojson >/dev/null 2>&1; then
  if kismetdb_to_geojson --in "${DB}" --out "${PRIMARY_GJ}" --device-types=Wi-Fi 2>/dev/null; then
    if [[ -s "${PRIMARY_GJ}" ]] && jq -e '.features|length>0' "${PRIMARY_GJ}" >/dev/null 2>&1; then
      TITLE="Wardrive — $(date +'%Y-%m-%d %H:%M')"
      python3 "${BASE_DIR}/make_map.py" --in "${PRIMARY_GJ}" --fallback "${FALLBACK_GJ}" --out "${OUT_HTML}" --title "${TITLE}"
      echo "[✓] Map created from kismetdb_to_geojson: ${OUT_HTML}"
      exit 0
    fi
  fi
fi

# --- No-GPS detection: if devices have 0 GPS, skip CSV path ------------------
NO_GPS_RUN=false
GPS_COUNT="$(
python3 - <<'PY'
import json, os
from pathlib import Path
p=Path(os.environ["DEV_JSON"])
n=0
if p.exists():
    try:
        D=json.loads(p.read_text(encoding='utf-8', errors='ignore'))
        for d in (D if isinstance(D,list) else []):
            loc=d.get("kismet.device.base.location") or {}
            if loc.get("kismet.common.location.lat") is not None and loc.get("kismet.common.location.lon") is not None:
                n+=1
    except Exception:
        pass
print(n)
PY
)"


if [[ "${GPS_COUNT}" -eq 0 ]]; then
  NO_GPS_RUN=true
  echo "[NoGPS] Detected a no-GPS run (0 devices with coordinates) — skipping CSV."
fi


# --- CSV path first (atomic, non-destructive) --------------------------------
if [[ "${DRY_RUN}" == true ]]; then
  echo "[DryRun] Skipping CSV export."
else
  if [[ "${NO_GPS_RUN:-false}" != true ]]; then
    if kismetdb_to_wiglecsv --in "${DB}" --out "${CSV_OUT}" --force 2>/dev/null; then
      TMP_GJ="${LOGDIR}/_tmp_from_csv.geojson"
      export TMP_GJ
      python3 - <<'PY'
  import csv, json, re, os, io
  from pathlib import Path
  csv_path = Path(os.environ["CSV_OUT"])
  out_path = Path(os.environ["TMP_GJ"])
  
  lines = []
  if csv_path.exists():
      raw = csv_path.read_text(encoding='utf-8', errors='ignore').splitlines()
      if raw and raw[0].startswith("WigleWifi"):
          raw = raw[1:]
      lines = raw
  
  feats = []
  if lines:
      rdr = csv.DictReader(io.StringIO("\n".join(lines)))
      for row in rdr:
          lat_s = (row.get("CurrentLatitude") or row.get("Trilat") or row.get("Latitude") or "").strip()
          lon_s = (row.get("CurrentLongitude") or row.get("Trilong") or row.get("Longitude") or "").strip()
          try:
              lat = float(lat_s); lon = float(lon_s)
          except Exception:
              continue
          if not (-90 <= lat <= 90 and -180 <= lon <= 180): continue
  
          sig = row.get("Signal dBm") or row.get("RSSI")
          if sig is not None:
              s = str(sig).strip().replace("\u2212","-")
              s = re.sub(r"\s*dBm?$","", s, flags=re.I)
              try: sig = float(s)
              except: sig = None
  
          raw_type = (row.get("Type") or "").strip().lower()
          t = "unknown"
          if raw_type in ("ap","access point","infrastructure","wifi"):
              t = "ap"
          elif any(x in raw_type for x in ("client","station","sta")):
              t = "client"
          elif "bridge" in raw_type:
              t = "bridge"
          elif (row.get("SSID") or row.get("NetworkName")) and row.get("Channel"):
              t = "ap"
  
          props = {
              "SSID": row.get("SSID") or row.get("NetworkName"),
              "BSSID": row.get("MAC") or row.get("BSSID"),
              "Channel": row.get("Channel"),
              "Encryption": row.get("AuthMode") or row.get("Encryption"),
              "Signal dBm": sig,
              "Type": t,
          }
          feats.append({"type":"Feature","geometry":{"type":"Point","coordinates":[lon,lat]},"properties":props})
  
  out_path.write_text(json.dumps({"type":"FeatureCollection","features":feats}, ensure_ascii=False), encoding='utf-8')
  print(f"[CSV] Wrote {len(feats)} features -> {out_path}")
PY
      CSV_TMP_FEATS="$(jq -r '(.features|length)//0' "${TMP_GJ}" 2>/dev/null || echo 0)"
      if [[ "${CSV_TMP_FEATS}" -gt 0 ]]; then
        mv -f "${TMP_GJ}" "${PRIMARY_GJ}"
        echo "[CSV] Promoted temp to PRIMARY_GJ (${CSV_TMP_FEATS} features)."
      else
        rm -f "${TMP_GJ}" 2>/dev/null || true
        echo "[!] CSV produced 0 features — keeping existing PRIMARY_GJ."
      fi
    else
       echo "[!] kismetdb_to_wiglecsv failed; continuing without CSV."
    fi
  else
    echo "[NoGPS] Skipping CSV path entirely."
  fi
fi


  # Enrich Type from devices.json (AP/Client/Bridge)
python3 - <<'PY'
import json, os
from pathlib import Path

gj_path = Path(os.environ["PRIMARY_GJ"])
dev_json = Path(os.environ["DEV_JSON"])
if not (gj_path.exists() and dev_json.exists()):
    print("[Types] Skipped enrichment (missing files)")
    raise SystemExit(0)

def norm_mac(s):
    if not isinstance(s, str): return ""
    return s.replace('-',':').upper()

def pick(obj, dotted):
    """
    Robust getter: supports either a nested dict at each step,
    OR a flattened single key with dots in the name.
    """
    # flattened form (e.g., "kismet.device.base.macaddr" at top level)
    if dotted in obj:
        return obj.get(dotted)
    # nested form
    cur = obj
    for part in dotted.split('.'):
        if isinstance(cur, dict) and part in cur:
            cur = cur[part]
        else:
            return None
    return cur

# Load devices.json (array, JSONL, or object-with-list)
txt = dev_json.read_text(encoding='utf-8', errors='ignore')
rows = []
try:
    data = json.loads(txt)
    if isinstance(data, list):
        rows = data
    elif isinstance(data, dict):
        # sometimes it's {"devices":[...]} or {"list":[...]} or a dict-of-devs
        if "devices" in data and isinstance(data["devices"], list):
            rows = data["devices"]
        elif "list" in data and isinstance(data["list"], list):
            rows = data["list"]
        else:
            # dict of device objects
            rows = list(data.values())
except Exception:
    rows = [json.loads(l) for l in txt.splitlines() if l.strip()]

typemap = {}
n_total = 0
n_mac = 0
n_typed = 0

for d in rows:
    if not isinstance(d, dict): 
        continue
    n_total += 1

    # MAC: prefer base.macaddr; fallbacks: base.key, dot11.bssid
    mac = (
        pick(d, "kismet.device.base.macaddr")
        or pick(d, "kismet.device.base.key")
        or pick(d, "dot11.device.bssid")
        or ""
    )
    mac = norm_mac(str(mac))
    if not mac:
        continue
    n_mac += 1

    # Type name from multiple possible fields (flattened or nested)
    tname = (
        (pick(d, "kismet.device.base.typename") or pick(d, "kismet.device.base.type") or "")
        or ""
    ).lower()

    # dot11 hint if typename missing
    typeset = str(pick(d, "dot11.device.typeset") or "").lower()

    t = "unknown"
    if any(w in tname for w in ("client","station"," sta")):
        t = "client"
    elif "bridge" in tname:
        t = "bridge"
    elif any(w in tname for w in ("ap","access point","infrastructure")):
        t = "ap"
    else:
        if any(w in typeset for w in ("client","station"," sta")):
            t = "client"
        elif "bridge" in typeset:
            t = "bridge"
        elif any(w in typeset for w in ("ap","infrastructure")):
            t = "ap"

    if t != "unknown":
        n_typed += 1
    typemap[mac] = t

# Rewrite types in the CSV-derived GeoJSON
gj = json.loads(gj_path.read_text(encoding='utf-8'))
changed = 0
for f in gj.get("features", []):
    p = f.get("properties", {})
    bssid = norm_mac(str(p.get("BSSID") or p.get("MAC") or ""))
    if bssid in typemap and typemap[bssid] != "unknown":
        if p.get("Type") != typemap[bssid]:
            p["Type"] = typemap[bssid]
            changed += 1

gj_path.write_text(json.dumps(gj, ensure_ascii=False), encoding='utf-8')

print(f"[Types] Devices total:{n_total} with-MAC:{n_mac} typed:{n_typed}  -> updated features:{changed} (typemap:{len(typemap)})")
PY

# Debug: how many non-AP devices actually have GPS in devices.json?
python3 - <<'PY'
import json, os
from pathlib import Path

dev_json = Path(os.environ["DEV_JSON"])
if not dev_json.exists():
    print("[Debug] devices.json missing")
    raise SystemExit(0)

txt = dev_json.read_text(encoding='utf-8', errors='ignore')
try:
    data = json.loads(txt)
    rows = data if isinstance(data, list) else (
        data.get("devices") if isinstance(data, dict) and isinstance(data.get("devices"), list) else
        data.get("list")    if isinstance(data, dict) and isinstance(data.get("list"), list) else
        (list(data.values()) if isinstance(data, dict) else [])
    )
except Exception:
    rows = [json.loads(l) for l in txt.splitlines() if l.strip()]

def pick(d, k):
    if k in d: return d[k]
    cur = d
    for part in k.split('.'):
        if isinstance(cur, dict) and part in cur: cur = cur[part]
        else: return None
    return cur

total = len(rows)
typed_nonap = 0
typed_nonap_with_gps = 0

for d in rows:
    tname = str(pick(d,"kismet.device.base.typename") or pick(d,"kismet.device.base.type") or "").lower()
    typeset = str(pick(d,"dot11.device.typeset") or "").lower()
    is_client = ("client" in tname or "station" in tname or " sta" in tname or
                 "client" in typeset or "station" in typeset or " sta" in typeset)
    is_bridge = ("bridge" in tname or "bridge" in typeset)
    is_ap = ("ap" in tname or "access point" in tname or "infrastructure" in tname or
             "ap" in typeset or "infrastructure" in typeset)

    if (is_client or is_bridge) and not is_ap:
        typed_nonap += 1
        lat = (pick(d,"kismet.device.base.gps_best_lat") or pick(d,"kismet.device.base.gps_last_lat") or
               pick(d,"kismet.device.base.gps_peak_lat") or pick(d,"kismet.device.base.gps_avg_lat") or
               pick(d,"kismet.device.base.gps_min_lat")  or pick(d,"kismet.device.base.gps_max_lat")  or
               (pick(d,"kismet.device.base.location") or {}).get("lat") or (pick(d,"kismet.device.base.location") or {}).get("latitude"))
        lon = (pick(d,"kismet.device.base.gps_best_lon") or pick(d,"kismet.device.base.gps_last_lon") or
               pick(d,"kismet.device.base.gps_peak_lon") or pick(d,"kismet.device.base.gps_avg_lon") or
               pick(d,"kismet.device.base.gps_min_lon")  or pick(d,"kismet.device.base.gps_max_lon")  or
               (pick(d,"kismet.device.base.location") or {}).get("lon") or (pick(d,"kismet.device.base.location") or {}).get("lng") or (pick(d,"kismet.device.base.location") or {}).get("longitude"))
        if lat is not None and lon is not None:
            typed_nonap_with_gps += 1

print(f"[Debug] devices total={total} typed_nonAP={typed_nonap} typed_nonAP_with_GPS={typed_nonap_with_gps}")
PY


# Merge non-AP devices: if they lack GPS, infer location from their last associated BSSID (AP)
python3 - <<'PY'
import json, os
from pathlib import Path

gj_path = Path(os.environ["PRIMARY_GJ"])
dev_path = Path(os.environ["DEV_JSON"])

def load_geojson(p):
    if not p.exists() or p.stat().st_size == 0:
        return {"type":"FeatureCollection","features":[]}
    return json.loads(p.read_text(encoding="utf-8"))

def extract_signal(props):
    for k in ("Signal dBm","signal","last_signal"):
        v = props.get(k)
        if v is None: 
            continue
        try:
            return float(str(v).replace("dBm","").strip())
        except Exception:
            pass
    return None

def extract_channel(props):
    return props.get("Channel") or props.get("channel") or ""

def extract_loc_from_device(d):
    """Try real GPS on the device first (rare for clients)."""
    loc = d.get("kismet.device.base.location") or {}
    lat = loc.get("kismet.common.location.lat") or loc.get("kismet.common.location.latitude")
    lon = loc.get("kismet.common.location.lon") or loc.get("kismet.common.location.longitude")
    try:
        if lat is not None and lon is not None:
            return (float(lon), float(lat))
    except Exception:
        pass
    return None

def last_bssid_from_device(d):
    return (d.get("dot11.device", {}).get("dot11.device.last_bssid") or "").strip().lower()

def mk_feature(lon, lat, props):
    return {
        "type": "Feature",
        "geometry": {"type": "Point", "coordinates": [lon, lat]},
        "properties": props,
    }

# 1) Load current GeoJSON and index AP coordinates + signal + channel
fc = load_geojson(gj_path)
ap_info = {}
for f in fc.get("features", []):
    props = f.get("properties", {}) or {}
    bssid = (props.get("BSSID") or props.get("MAC") or "").strip().lower()
    if not bssid:
        continue
    try:
        lon, lat = f["geometry"]["coordinates"][:2]
        ap_info[bssid] = (float(lon), float(lat), extract_signal(props), extract_channel(props))
    except Exception:
        continue

# 2) Walk devices.json and add non-AP Wi-Fi devices
added = 0
try:
    devs = json.loads(dev_path.read_text(encoding="utf-8"))
except Exception:
    devs = []

for d in devs:
    dtype = d.get("kismet.device.base.type","")
    if not dtype.startswith("Wi-Fi") or dtype == "Wi-Fi AP":
        continue  # only non-AP Wi-Fi devices

    mac = (d.get("kismet.device.base.macaddr") or "").strip().lower()
    if not mac:
        continue

    # Prefer real GPS on device (rare)
    real = extract_loc_from_device(d)
    if real:
        lon, lat = real
        props = {
            "Type": "Client",
            "BSSID": mac,
            "Inferred": False,
            "InferredFromBSSID": "",
            "Note": "client-with-real-gps",
        }
        fc["features"].append(mk_feature(lon, lat, props))
        added += 1
        continue

    # No GPS: infer from last associated BSSID
    ap_bssid = last_bssid_from_device(d)          # <-- defined properly now
    if not ap_bssid:
        continue
    ap = ap_info.get(ap_bssid)
    if not ap:
        continue
    lon, lat, ap_sig, ap_chan = ap
    props = {
        "Type": "Client",                         # use canonical type so legend colors it correctly
        "BSSID": mac,
        "Inferred": True,                         # mark as inferred
        "InferredFromBSSID": ap_bssid,
        "Note": "placed_at_ap_location",
    }
    if ap_sig is not None:
        props["Signal dBm"] = ap_sig              # helps the slider
    if ap_chan:
        props["Channel"] = ap_chan                # helps channel coloring/filters
    fc["features"].append(mk_feature(lon, lat, props))
    added += 1

gj_path.write_text(json.dumps(fc, ensure_ascii=False, indent=2), encoding="utf-8")
print(f"[Merge] Added non-AP devices: {added}")
PY

# Infer AP coords for APs with no GPS today, using last-known coords from the accumulator
python3 - <<'PY'
import json, os
from pathlib import Path

curr_gj = Path(os.environ["PRIMARY_GJ"])                  # today's geojson
prev_gj = Path(str(curr_gj).replace(".geojson",".geojson.prev"))  # accumulator from prior runs
dev_path = Path(os.environ.get("DEV_JSON",""))

def load_fc(p):
    if not p.exists() or p.stat().st_size == 0:
        return {"type":"FeatureCollection","features":[]}
    return json.loads(p.read_text(encoding="utf-8"))

curr = load_fc(curr_gj)
prev = load_fc(prev_gj)

# Index previous known AP locations: BSSID -> (lon, lat, props)
prev_idx = {}
for f in prev.get("features", []):
    props = f.get("properties", {}) or {}
    b = (props.get("BSSID") or props.get("MAC") or "").strip().lower()
    if not b: continue
    try:
      lon, lat = f["geometry"]["coordinates"][:2]
    except Exception:
      continue
    prev_idx[b] = (float(lon), float(lat), props)

# BSSIDs already present in today's file (with GPS or already added)
have_today = set()
for f in curr.get("features", []):
    p = f.get("properties", {}) or {}
    b = (p.get("BSSID") or p.get("MAC") or "").strip().lower()
    if b: have_today.add(b)

# Load devices.json to discover APs seen today
try:
    devices = json.loads(dev_path.read_text(encoding="utf-8")) if dev_path.exists() else []
except Exception:
    devices = []

added = 0
for d in devices:
    if d.get("kismet.device.base.type","") != "Wi-Fi AP":
        continue
    bssid = (d.get("kismet.device.base.macaddr") or "").strip().lower()
    if not bssid or bssid in have_today:
        continue
    prev_hit = prev_idx.get(bssid)
    if not prev_hit:
        continue  # never seen with GPS before
    lon, lat, pprops = prev_hit
    props = {
        "Type": "AP",
        "BSSID": bssid,
        "SSID": d.get("kismet.device.base.commonname") or pprops.get("SSID") or "",
        "Channel": d.get("kismet.device.base.channel") or pprops.get("Channel") or "",
        "Signal dBm": pprops.get("Signal dBm"),
        "Inferred": True,
        "Note": "ap_inferred_from_previous_run"
    }
    curr["features"].append({
        "type":"Feature",
        "geometry":{"type":"Point","coordinates":[lon,lat]},
        "properties": props
    })
    added += 1

curr_gj.write_text(json.dumps(curr, ensure_ascii=False, indent=2), encoding="utf-8")
print(f"[NoGPS] Inferred APs from previous runs: {added}")
PY

  # If CSV produced 0 features, log and continue (do NOT exit)
  FEAT_COUNT="$(
    python3 - <<'PY'
import json, os
from pathlib import Path
p = Path(os.environ["PRIMARY_GJ"])
try:
  d = json.loads(p.read_text(encoding='utf-8')) if p.exists() else {}
  print(len(d.get('features', [])))
except Exception:
  print(0)
PY
  )"
  if [[ "${FEAT_COUNT}" -gt 0 ]]; then
    CSV_OK=true
  else
    echo "[!] CSV path produced 0 features (likely no GPS) — continuing to inference."
  fi

# --- Fallback JSON path ------------------------------------------------------
CSV_OK=false

if [[ "${CSV_OK}" != true ]]; then
  if [[ -s "${DEV_JSON}" ]]; then
    python3 - <<'PY'
import json, os
from pathlib import Path
inp = Path(os.environ["DEV_JSON"])
out = Path(os.environ["FALLBACK_GJ"])
feats=[]
if inp.exists():
  txt = inp.read_text(encoding='utf-8', errors='ignore')
  # JSON array or JSON-lines
  try:
    data = json.loads(txt)
    lines = data if isinstance(data, list) else []
  except Exception:
    lines = [json.loads(l) for l in txt.splitlines() if l.strip()]

  def pick_lat_lon(base: dict):
    for latk, lonk in [
      ("gps_best_lat","gps_best_lon"),
      ("gps_last_lat","gps_last_lon"),
      ("gps_peak_lat","gps_peak_lon"),
      ("gps_avg_lat","gps_avg_lon"),
      ("gps_min_lat","gps_min_lon"),
      ("gps_max_lat","gps_max_lon"),
    ]:
      lat = base.get(latk); lon = base.get(lonk)
      try:
        if lat is not None and lon is not None:
          return float(lat), float(lon)
      except Exception:
        pass
    loc = base.get("location", {})
    if isinstance(loc, dict):
      lat = loc.get("lat") or loc.get("latitude")
      lon = loc.get("lon") or loc.get("lng") or loc.get("longitude")
      try:
        if lat is not None and lon is not None:
          return float(lat), float(lon)
      except Exception:
        pass
    return None, None

  for d in lines:
    if not isinstance(d, dict):
      continue
    base = d.get('kismet.device.base', {}) if isinstance(d.get('kismet.device.base'), dict) else {}
    lat, lon = pick_lat_lon(base)
    if lat is None or lon is None:
      continue
    dot11 = d.get('dot11.device', {}) if isinstance(d.get('dot11.device'), dict) else {}
    sig = None
    sigblk = base.get('signal', {})
    if isinstance(sigblk, dict):
      sig = sigblk.get('last_signal') or sigblk.get('best_signal') or sigblk.get('peak_signal')

    # normalize type a bit from base/dot11
    tname = (base.get('typename') or base.get('type') or '').lower()
    t = 'unknown'
    if any(w in tname for w in ('client','station',' sta')): t='client'
    elif 'bridge' in tname: t='bridge'
    elif any(w in tname for w in ('ap','access point','infrastructure')): t='ap'

    props = {
      'SSID': dot11.get('ssid',''),
      'BSSID': base.get('macaddr') or base.get('key',''),
      'Signal dBm': sig,
      'Type': t
    }
    feats.append({'type':'Feature','geometry':{'type':'Point','coordinates':[lon,lat]},'properties':props})

out.write_text(json.dumps({'type':'FeatureCollection','features':feats}, ensure_ascii=False), encoding='utf-8')
print(f"[JSON] Wrote {len(feats)} features -> {out}")
PY
    echo "[JSON] Wrote fallback GeoJSON -> ${FALLBACK_GJ}"
  else
    echo "[!] No devices dump; fallback JSON skipped."
  fi
fi

python3 - <<'PY'
import json, os
from pathlib import Path

gj = Path(os.environ["PRIMARY_GJ"])
dev = Path(os.environ["DEV_JSON"])

def load_fc(p):
    if not p.exists(): return {"type":"FeatureCollection","features":[]}
    try: return json.loads(p.read_text(encoding="utf-8"))
    except: return {"type":"FeatureCollection","features":[]}

def load_devices(p):
    if not p.exists(): return []
    try: return json.loads(p.read_text(encoding="utf-8"))
    except: return []

fc = load_fc(gj)
devices = load_devices(dev)

# Build index: BSSID -> {channel, encryption string}
idx = {}
for d in devices:
    if d.get("kismet.device.base.type") != "Wi-Fi AP":
        continue
    base = d.get("kismet.device.base", {}) or {}
    mac = (base.get("macaddr") or "").strip().lower()
    if not mac: continue
    ch = base.get("channel") or ""
    # Try to derive encryption flags
    dot11 = d.get("dot11.device", {}) or {}
    encset = set()
    for k in ("crypt","wifi_crypt","dot11.device.last_beaconed_ssid.crypt"):
        v = dot11.get(k)
        if isinstance(v, list): encset.update([str(x).upper() for x in v])
        elif isinstance(v, str): encset.add(v.upper())
    # Simplify a bit
    enc = ",".join(sorted(encset)) if encset else ""
    idx[mac] = {"Channel": str(ch), "Encryption": enc}

updated = 0
for f in fc.get("features", []):
    p = f.get("properties", {}) or {}
    if (p.get("Type") or "").lower() != "ap":
        continue
    mac = (p.get("BSSID") or p.get("MAC") or "").strip().lower()
    if not mac: continue
    info = idx.get(mac)
    if not info: continue
    changed = False
    if info["Channel"] and p.get("Channel") != info["Channel"]:
        p["Channel"] = info["Channel"]; changed = True
    if info["Encryption"] and p.get("Encryption") != info["Encryption"]:
        p["Encryption"] = info["Encryption"]; changed = True
    if changed:
        f["properties"] = p
        updated += 1

if updated:
    gj.write_text(json.dumps(fc, ensure_ascii=False, indent=2), encoding="utf-8")
print(f"[Enrich] Updated encryption/channel on APs: {updated}")
PY


# --- MergeRuns: write union to .prev (de-duplicated) ------------------------
python3 - <<'PY'
import json, os
from pathlib import Path

pg = Path(os.environ["PRIMARY_GJ"])                      # this run
acc = Path(str(pg).replace(".geojson",".geojson.prev"))  # accumulator

def load_fc(p):
    if not p.exists() or p.stat().st_size == 0:
        return {"type":"FeatureCollection","features":[]}
    try:
        return json.loads(p.read_text(encoding="utf-8"))
    except Exception:
        return {"type":"FeatureCollection","features":[]}

prev = load_fc(acc)
curr = load_fc(pg)

prev_feats = prev.get("features", [])
curr_feats = curr.get("features", [])

def key_for(f):
    p = f.get("properties", {}) or {}
    t = (p.get("Type") or "").strip().lower()
    mac = (p.get("BSSID") or p.get("MAC") or "").strip().lower()
    if t == "ap" and mac: return ("ap", mac)
    if mac: return ("dev", mac)
    try:
        lon, lat = f["geometry"]["coordinates"][:2]
        return ("xy", round(float(lon),6), round(float(lat),6))
    except Exception:
        return ("id", id(f))

idx = {}
merged = []

for f in prev_feats:
    k = key_for(f)
    if k in idx: continue
    idx[k]=1; merged.append(f)

added=0
for f in curr_feats:
    k = key_for(f)
    if k in idx: continue
    idx[k]=1; merged.append(f); added+=1

acc.write_text(json.dumps({"type":"FeatureCollection","features":merged}, ensure_ascii=False, indent=2), encoding="utf-8")
print(f"[MergeRuns] prev={len(prev_feats)} new={len(curr_feats)} -> merged={len(merged)} (added {added})")
PY

# --- Choose source GeoJSON (use accumulator) ---------------------------------
ACCUM_GJ="${PRIMARY_GJ%.geojson}.geojson.prev"
SRC_GJ="${ACCUM_GJ}"
export SRC_GJ ACCUM_GJ

# --- Stats + Snapshot ---------------------------------------------------------
SNAP_DATE="$(date +'%Y%m%d-%H%M%S')"
SNAP_GJ="${DATADIR:-${LOGDIR}}/snapshots/networks_${SNAP_DATE}.geojson"
mkdir -p "$(dirname "${SNAP_GJ}")"

python3 - <<'PY'
import json, os, collections
from pathlib import Path

acc = Path(os.environ.get("ACCUM_GJ") or "")
# default to LOGDIR/data if DATADIR is unset/blank
datadir = os.environ.get("DATADIR") or (Path(os.environ.get("LOGDIR",".")) / "data")
out_dir = Path(datadir) / "stats"
snap_dir = Path(datadir) / "snapshots"
snap_dir.mkdir(parents=True, exist_ok=True)
out_dir.mkdir(parents=True, exist_ok=True)

# build a real file path for the snapshot
snap = snap_dir / f"networks_{__import__('time').strftime('%Y%m%d-%H%M%S')}.geojson"


def load_fc(p):
    if not p or not p.exists() or p.stat().st_size==0: return {"type":"FeatureCollection","features":[]}
    try: return json.loads(p.read_text(encoding="utf-8"))
    except Exception: return {"type":"FeatureCollection","features":[]}

fc = load_fc(acc)
feats = fc.get("features", [])

tot = len(feats)
by_type = collections.Counter()
inferred = 0
with_ssid = 0
enc_counter = collections.Counter()
chan_counter = collections.Counter()
gps_points = 0  # geometry presence

for f in feats:
    p = f.get("properties",{}) or {}
    t = (p.get("Type") or "").strip().lower() or "unknown"
    by_type[t]+=1
    if p.get("Inferred") is True: inferred += 1
    if p.get("SSID"): with_ssid += 1
    # encryption/channel (APs only if present)
    enc = (p.get("Encryption") or "").strip().upper()
    if enc: enc_counter[enc]+=1
    ch = (p.get("Channel") or "").strip()
    if ch: chan_counter[ch]+=1
    # gps presence (any point has geometry; treat non-inferred as "from GPS at some time")
    if f.get("geometry",{}).get("type") == "Point": gps_points += 1

summary = {
  "total_features": tot,
  "by_type": dict(by_type),
  "inferred_count": inferred,
  "non_inferred_count": tot - inferred,
  "ssid_present_count": with_ssid,
  "encryption_counts": dict(enc_counter),
  "channel_counts": dict(chan_counter),
  "gps_point_features": gps_points,   # informational
}

(out_dir / "summary.json").write_text(json.dumps(summary, indent=2, ensure_ascii=False), encoding="utf-8")
# also write top-N channels/encryption as quick CSVs
def write_counts_csv(counter, path):
    with open(path, "w", encoding="utf-8") as w:
        w.write("key,count\n")
        for k,c in counter.most_common():
            w.write(f"{k},{c}\n")

write_counts_csv(enc_counter, str(out_dir / "encryption_counts.csv"))
write_counts_csv(chan_counter, str(out_dir / "channel_counts.csv"))

# snapshot the current accumulator so you can track over time
if acc.exists():
    snap.write_text(json.dumps(fc, ensure_ascii=False), encoding="utf-8")
    print(f"[Stats] summary.json + counts written; snapshot -> {snap}")
else:
    print("[Stats] accumulator missing; skipped snapshot.")
PY


# Verify we have features to map (on the accumulator!)
HAS_FEATS="$(jq -r '(.features|length)//0' "${SRC_GJ}" 2>/dev/null || echo 0)"
echo "[Counts] accumulated=${HAS_FEATS}"
if [[ "${HAS_FEATS}" -eq 0 ]]; then
  echo "[!] Nothing to map."; exit 3
fi


# --- Build HTML --------------------------------------------------------------
if [[ "${DRY_RUN}" == true ]]; then
  echo "[DryRun] Skipping HTML render."
else
  TITLE="Wardrive — $(date +'%Y-%m-%d %H:%M')"
  python3 "${BASE_DIR}/make_map.py" --in "${SRC_GJ}" --fallback "${FALLBACK_GJ}" --out "${OUT_HTML}" --title "${TITLE}"
  echo "[✓] Map created: ${OUT_HTML}"
fi
