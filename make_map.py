#!/usr/bin/env python3
"""
make_map.py — build a Leaflet HTML map from wardriving GeoJSON with switchable coloring modes

Features
- Two coloring modes: By Type (AP / Client / Bridge / Unknown) and By Signal Strength
- Filter panel: toggle device types, minimum signal (dBm) slider, SSID search
- Dynamic legend and live re-coloring without regenerating data
- Marker clustering for performance

Usage
    python make_map.py \
        --in data/networks_fixed.geojson \
        --fallback data/networks_geojson_fallback.geojson \
        --out data/networks_colored.html \
        --title "Wardrive Map"

Notes
- The script embeds the GeoJSON directly into the HTML for simplicity (< ~10–20k points).
- If you expect very large datasets, consider switching to a fetch() of a .geojson file on your webserver.
"""

from __future__ import annotations
import argparse
import json
import re
from pathlib import Path
from datetime import datetime

# ------------------------- Helpers -------------------------

def coerce_float(val):
    if val is None:
        return None
    if isinstance(val, (int, float)):
        return float(val)
    # normalize weird unicode minus and strip units like " dBm", "dbm"
    s = str(val).strip()
    s = s.replace("\u2212", "-")  # Unicode minus to ASCII hyphen
    s = re.sub(r"\s*dBm?$", "", s, flags=re.IGNORECASE)
    s = s.replace(",", ".")
    try:
        return float(s)
    except ValueError:
        return None

# Attempt to find a signal (last/strongest) in common Kismet/Wigle schemas
SIGNAL_KEYS = [
    "Signal dBm",  # Wigle export normalized by your pipeline
    "signal_dbm",
    "kismet.device.base.signal.kismet.common.signal.last_signal",
    "kismet.device.base.signal/kismet.common.signal.last_signal",
    "kismet.common.signal.last_signal",
    "last_signal",
    "signal",
]

# Try to infer device type from various schemas/text fields
TYPE_KEYS = [
    "type", "Type", "device_type", "kismet.device.base.type",
    "dot11.device.type", "kismet.device.base.typename", "typename",
]


def infer_type(props: dict) -> str:
    text = " ".join(str(props.get(k, "")) for k in TYPE_KEYS).lower()
    # Heuristics
    if any(x in text for x in ["bridge", "bridged"]):
        return "bridge"
    if any(x in text for x in ["ap", "access point", "infrastructure", "base station"]):
        return "ap"
    if any(x in text for x in ["client", "station", "sta", "phone", "laptop"]):
        return "client"
    # fallbacks using capabilities/encryption hints if present
    if "ssid" in props and props.get("ssid"):
        return "ap"  # many exports list AP features with SSID
    return "unknown"


def extract_signal_dbm(props: dict) -> float | None:
    for key in SIGNAL_KEYS:
        if key in props:
            val = coerce_float(props.get(key))
            if val is not None:
                return val
    # Sometimes nested under "signal" dicts
    for k, v in props.items():
        if isinstance(v, dict):
            # search shallow nested keys
            for kk, vv in v.items():
                if any(p in kk.lower() for p in ["signal", "dbm"]):
                    cand = coerce_float(vv)
                    if cand is not None:
                        return cand
    return None


def load_geojson(primary: Path, fallback: Path | None) -> dict:
    if primary and primary.exists():
        return json.loads(primary.read_text(encoding="utf-8"))
    if fallback and fallback.exists():
        return json.loads(fallback.read_text(encoding="utf-8"))
    raise FileNotFoundError("No GeoJSON found. Provide --in or --fallback that exists.")


# ------------------------- HTML Builder -------------------------

LEAFLET_CSS = "https://unpkg.com/leaflet@1.9.4/dist/leaflet.css"
LEAFLET_JS = "https://unpkg.com/leaflet@1.9.4/dist/leaflet.js"
CLUSTER_CSS = "https://unpkg.com/leaflet.markercluster@1.5.3/dist/MarkerCluster.css"
CLUSTER_CSS_DEFAULT = "https://unpkg.com/leaflet.markercluster@1.5.3/dist/MarkerCluster.Default.css"
CLUSTER_JS = "https://unpkg.com/leaflet.markercluster@1.5.3/dist/leaflet.markercluster.js"


HTML_TEMPLATE = """<!doctype html>
<html lang=\"en\">
<head>
  <meta charset=\"utf-8\" />
  <meta name=\"viewport\" content=\"width=device-width, initial-scale=1\" />
  <title>{title}</title>
  <link rel=\"stylesheet\" href=\"{leaflet_css}\" />
  <link rel=\"stylesheet\" href=\"{cluster_css}\" />
  <link rel=\"stylesheet\" href=\"{cluster_css_default}\" />
  <style>
    html, body, #map { height: 100%; margin: 0; }
    .topbar {
      position: absolute; z-index: 1000; top: 10px; left: 50%; transform: translateX(-50%);
      background: rgba(255,255,255,0.95); padding: 8px 12px; border-radius: 12px; box-shadow: 0 2px 12px rgba(0,0,0,0.15);
      font-family: system-ui, -apple-system, Segoe UI, Roboto, Ubuntu, 'Helvetica Neue', Arial, 'Noto Sans', sans-serif;
      display: flex; gap: 16px; align-items: center; flex-wrap: wrap;
    }
    .legend { font-size: 12px; display:flex; gap:10px; align-items:center; }
    .legend .swatch { width: 12px; height: 12px; border-radius: 3px; display:inline-block; margin-right:4px; border:1px solid rgba(0,0,0,0.2); }
    .panel { position:absolute; z-index:1000; top:70px; right:10px; width:290px; background:rgba(255,255,255,0.97); border-radius:14px; box-shadow:0 2px 12px rgba(0,0,0,0.15); padding:12px; font-family: system-ui, -apple-system, Segoe UI, Roboto, Ubuntu, 'Helvetica Neue', Arial, 'Noto Sans', sans-serif; }
    .panel h3 { margin: 0 0 8px 0; font-size:14px; }
    .panel label { display:block; font-size:13px; margin:6px 0; }
    .panel .row { display:flex; gap:8px; align-items:center; }
    .count-pill { background:#000; color:#fff; padding:3px 8px; border-radius:999px; font-size:12px; }
    .footer { position:absolute; z-index:1000; bottom:10px; right:10px; background:rgba(255,255,255,0.9); padding:6px 10px; border-radius:10px; font-size:12px; font-family: system-ui; }
  </style>
</head>
<body>
  <div id=\"map\"></div>

  <div class=\"topbar\">
    <strong>{title}</strong>
    <div class=\"mode row\">
      <label class=\"row\"><input type=\"radio\" name=\"mode\" value=\"type\" checked> By type</label>
      <label class=\"row\"><input type=\"radio\" name=\"mode\" value=\"signal\"> By signal</label>
      <span class=\"count-pill\" id=\"count\">0</span>
    </div>
    <div class=\"legend\" id=\"legend\"></div>
  </div>

  <div class=\"panel\">
    <h3>Filters</h3>
    <label><input type=\"checkbox\" class=\"flt-type\" value=\"ap\" checked> Access Points</label>
    <label><input type=\"checkbox\" class=\"flt-type\" value=\"client\" checked> Clients</label>
    <label><input type=\"checkbox\" class=\"flt-type\" value=\"bridge\" checked> Bridges</label>
    <label><input type=\"checkbox\" class=\"flt-type\" value=\"unknown\" checked> Unknown</label>

    <label>Min signal (dBm): <span id=\"sigval\">-120</span>
      <input type=\"range\" id=\"minsig\" min=\"-120\" max=\"-20\" step=\"1\" value=\"-120\" />
    </label>

    <label>SSID contains:
      <input type=\"text\" id=\"ssidq\" placeholder=\"e.g., eduroam\" />
    </label>

    <button id=\"reset\">Reset filters</button>
  </div>

  <div class=\"footer\">Generated: {generated}</div>

  <script src=\"{leaflet_js}\"></script>
  <script src=\"{cluster_js}\"></script>
  <script>
  // --- Embedded data ---
  const GEOJSON = {geojson};

  // --- Utilities ---
  function coerceFloat(x) {
    if (x === null || x === undefined) return null;
    if (typeof x === 'number') return x;
    let s = String(x).trim().replace('\u2212','-').replace(/\s*dBm?$/i,'');
    s = s.replace(',', '.');
    const v = parseFloat(s);
    return Number.isFinite(v) ? v : null;
  }

  const SIGNAL_KEYS = {signal_keys};
  const TYPE_KEYS = {type_keys};

  function extractSignal(props) {
    for (const k of SIGNAL_KEYS) {
      if (k in props) {
        const v = coerceFloat(props[k]);
        if (v !== null) return v;
      }
    }
    for (const [k, v] of Object.entries(props)) {
      if (v && typeof v === 'object') {
        for (const [kk, vv] of Object.entries(v)) {
          if (/(signal|dbm)/i.test(kk)) {
            const c = coerceFloat(vv);
            if (c !== null) return c;
          }
        }
      }
    }
    return null;
  }

  function inferType(props) {
    const raw = TYPE_KEYS.map(k => (props[k] || '')).join(' ').toLowerCase();
  
    // Prefer explicit field if present
    const explicit = (props['Type'] || props['type'] || '').toString().trim().toLowerCase();
    if (explicit === 'client') return 'client';
    if (explicit === 'ap' || explicit === 'access point') return 'ap';
    if (explicit === 'bridge') return 'bridge';

    // Normalize common variants
    if (/\bbridge|bridged\b/.test(raw)) return 'bridge';
    if (/\bclient|station|\bsta\b/.test(raw)) return 'client';
  
    // Treat Wigle "WIFI" as an AP
    if (/\bwifi\b/.test(raw)) return 'ap';
  
    // Heuristics: having an SSID + Channel typically means AP
    const hasSsid = !!(props['SSID'] || props['ssid'] || props['dot11.device.ssid']);
    const hasChan = !!(props['Channel'] || props['channel'] || props['kismet.device.base.channel']);
    if (hasSsid && hasChan) return 'ap';
  
    // Fallback: if any encryption hint present, bias to AP
    const enc = (props['Encryption'] || props['encryption'] || '').toString().toLowerCase();
    if (enc && enc !== 'unknown' && enc !== 'open') return 'ap';
  
    return 'unknown';
  }


  // Colors for type mode (matching your earlier scheme)
  const TYPE_COLORS = {
    bridge: '#1e88e5', // blue
    ap: '#43a047',     // green
    client: '#fb8c00', // orange
    unknown: '#9e9e9e' // gray
  };

  // Colors for signal mode
  function colorBySignal(dbm) {
    if (dbm === null) return '#9e9e9e';
    if (dbm >= -60) return '#2e7d32'; // strong
    if (dbm >= -75) return '#f9a825'; // medium
    return '#c62828'; // weak
  }

  function signalBucket(dbm) {
    if (dbm === null) return 'N/A';
    if (dbm >= -60) return '≥ -60 dBm';
    if (dbm >= -75) return '-75 to -60 dBm';
    return '< -75 dBm';
  }

  // Build map
  const map = L.map('map');
  const tiles = L.tileLayer('https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png', {
    maxZoom: 19,
    attribution: '&copy; OpenStreetMap contributors'
  }).addTo(map);

  const cluster = L.markerClusterGroup();

  // Build markers with cached props
  const features = GEOJSON.features || [];
  const items = features.map((f) => {
    const p = f.properties || {};
    const s = extractSignal(p);
    const t = inferType(p);
    const latlng = f.geometry && f.geometry.coordinates && f.geometry.coordinates.length >= 2 ? [f.geometry.coordinates[1], f.geometry.coordinates[0]] : null;
    return {
      latlng,
      props: p,
      signal: s,
      type: t,
      raw: f,
      marker: null,
    };
  }).filter(x => Array.isArray(x.latlng));

  // Initial bounds
  if (items.length) {
    const bounds = L.latLngBounds(items.map(i => i.latlng));
    map.fitBounds(bounds.pad(0.1));
  } else {
    map.setView([47.4979, 19.0402], 12); // Budapest default
  }

  // Controls
  const modeEls = Array.from(document.querySelectorAll('input[name="mode"]'));
  const legendEl = document.getElementById('legend');
  const countEl = document.getElementById('count');
  const minsigEl = document.getElementById('minsig');
  const sigvalEl = document.getElementById('sigval');
  const typeEls = Array.from(document.querySelectorAll('.flt-type'));
  const ssidqEl = document.getElementById('ssidq');
  document.getElementById('reset').addEventListener('click', () => {
    modeEls.find(r => r.value==='type').checked = true;
    minsigEl.value = -120; sigvalEl.textContent = '-120';
    typeEls.forEach(c => c.checked = true);
    ssidqEl.value = '';
    refresh();
  });

  minsigEl.addEventListener('input', () => { sigvalEl.textContent = minsigEl.value; refresh(); });
  typeEls.forEach(el => el.addEventListener('change', refresh));
  modeEls.forEach(el => el.addEventListener('change', refresh));
  ssidqEl.addEventListener('input', () => {
    // debounce-lite
    clearTimeout(window.__ssid_t);
    window.__ssid_t = setTimeout(refresh, 200);
  });

  function currentMode() {
    return modeEls.find(r => r.checked).value; // 'type' | 'signal'
  }

  function activeTypes() {
    return new Set(typeEls.filter(c => c.checked).map(c => c.value));
  }

  function ssidQuery() {
    return (ssidqEl.value || '').trim().toLowerCase();
  }

  function passesFilters(it) {
    if (!activeTypes().has(it.type)) return false;
    const minSig = parseFloat(minsigEl.value);
    if (Number.isFinite(minSig)) {
      if (it.signal !== null && it.signal < minSig) return false;
    }
    const q = ssidQuery();
    if (q) {
      const ssid = (it.props['SSID'] || it.props['ssid'] || it.props['dot11.device.ssid'] || '').toString().toLowerCase();
      if (!ssid.includes(q)) return false;
    }
    return true;
  }

  function markerStyle(it) {
    if (currentMode() === 'type') {
      return TYPE_COLORS[it.type] || TYPE_COLORS.unknown;
    } else {
      return colorBySignal(it.signal);
    }
  }

  function updateLegend() {
    if (currentMode() === 'type') {
      legendEl.innerHTML = `
        <span><span class="swatch" style="background:${TYPE_COLORS.ap}"></span>AP</span>
        <span><span class="swatch" style="background:${TYPE_COLORS.client}"></span>Client</span>
        <span><span class="swatch" style="background:${TYPE_COLORS.bridge}"></span>Bridge</span>
        <span><span class="swatch" style="background:${TYPE_COLORS.unknown}"></span>Unknown</span>
      `;
    } else {
      // signal legend
      legendEl.innerHTML = `
        <span><span class="swatch" style="background:#2e7d32"></span>≥ -60</span>
        <span><span class="swatch" style="background:#f9a825"></span>-75..-60</span>
        <span><span class="swatch" style="background:#c62828"></span>< -75</span>
        <span><span class="swatch" style="background:#9e9e9e"></span>N/A</span>
      `;
    }
  }

  function buildPopup(it) {
    const p = it.props;
    const ssid = p['SSID'] || p['ssid'] || p['dot11.device.ssid'] || '(hidden)';
    const bssid = p['BSSID'] || p['bssid'] || p['dot11.device.bssid'] || '—';
    const ch = p['Channel'] || p['channel'] || p['kismet.device.base.channel'] || '—';
    const enc = p['Encryption'] || p['encryption'] || p['dot11.device.encryption'] || '—';
    const dbm = it.signal !== null ? `${it.signal.toFixed(0)} dBm` : 'N/A';
    const sigb = signalBucket(it.signal);

    return `
      <div style="font-family: system-ui; font-size: 13px;">
        <div style="font-weight:600; font-size:14px; margin-bottom:4px;">${ssid}</div>
        <div><b>BSSID:</b> ${bssid}</div>
        <div><b>Type:</b> ${it.type}</div>
        <div><b>Signal:</b> ${dbm} <small>(${sigb})</small></div>
        <div><b>Channel:</b> ${ch}</div>
        <div><b>Encryption:</b> ${enc}</div>
      </div>
    `;
  }

  function ensureMarker(it) {
    if (it.marker) return it.marker;
    const color = markerStyle(it);
    const m = L.circleMarker(it.latlng, { radius: 6, weight: 1, color: '#222', fillColor: color, fillOpacity: 0.85 });
    m.bindPopup(buildPopup(it));
    it.marker = m;
    return m;
  }

  function refresh() {
    updateLegend();
    cluster.clearLayers();
    let shown = 0;
    for (const it of items) {
      const color = markerStyle(it);
      if (it.marker) {
        it.marker.setStyle({ fillColor: color });
        it.marker.setPopupContent(buildPopup(it));
      }
      if (passesFilters(it)) {
        cluster.addLayer(ensureMarker(it));
        shown++;
      }
    }
    if (!map.hasLayer(cluster)) map.addLayer(cluster);
    countEl.textContent = String(shown);
  }

  // Initial render
  updateLegend();
  refresh();

  // Fit to current filtered markers when data changes drastically (optional)
  function fitToShown() {
    const group = new L.featureGroup(cluster.getLayers());
    try { map.fitBounds(group.getBounds().pad(0.1)); } catch(e) { /* ignore when empty */ }
  }

  // Optional: double-click the count pill to zoom to shown
  countEl.addEventListener('dblclick', fitToShown);

  </script>
</body>
</html>
"""


def build_html(geojson: dict, title: str) -> str:
    # Manual, targeted replacements so JS/CSS braces aren’t interpreted by Python
    mapping = {
        "title": title,
        "leaflet_css": LEAFLET_CSS,
        "leaflet_js": LEAFLET_JS,
        "cluster_css": CLUSTER_CSS,
        "cluster_css_default": CLUSTER_CSS_DEFAULT,
        "cluster_js": CLUSTER_JS,
        "geojson": json.dumps(geojson, ensure_ascii=False),
        "signal_keys": json.dumps(SIGNAL_KEYS, ensure_ascii=False),
        "type_keys": json.dumps(TYPE_KEYS, ensure_ascii=False),
        "generated": datetime.utcnow().strftime("%Y-%m-%d %H:%M UTC"),
    }

    html = HTML_TEMPLATE
    for k, v in mapping.items():
        html = html.replace("{" + k + "}", v)
    return html




def main():
    ap = argparse.ArgumentParser(description="Build Leaflet HTML map with dual coloring modes")
    ap.add_argument("--in", dest="inp", default="data/networks_fixed.geojson", type=Path, help="Primary GeoJSON path")
    ap.add_argument("--fallback", dest="fallback", default="data/networks_geojson_fallback.geojson", type=Path, help="Fallback GeoJSON path")
    ap.add_argument("--out", dest="out", default="data/networks_colored.html", type=Path, help="Output HTML path")
    ap.add_argument("--title", dest="title", default="Wardrive Map", help="Map title")
    args = ap.parse_args()

    geo = load_geojson(args.inp, args.fallback)

    # Basic validation: ensure FeatureCollection
    if geo.get("type") != "FeatureCollection":
        # try to wrap if it's a list of features
        if isinstance(geo, dict) and "features" in geo:
            geo["type"] = "FeatureCollection"
        else:
            raise ValueError("Input is not a GeoJSON FeatureCollection")

    html = build_html(geo, args.title)
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(html, encoding="utf-8")
    print(f"Wrote map: {args.out}")


if __name__ == "__main__":
    main()
