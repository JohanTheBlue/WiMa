# 🛰️ Wardrive — Automated Wi-Fi Mapping Pipeline

Wardrive is a lightweight end-to-end toolkit for **collecting, processing, and visualizing Wi-Fi data** from [Kismet](https://www.kismetwireless.net) logs.

It turns raw `.kismet` databases or `.netxml` exports into **GeoJSON**, **stats summaries**, and a fully-interactive **Leaflet map**.

---

## 🚀 Features

- Automatic detection of the latest Kismet log
- Converts Kismet DB → `devices.json` → GeoJSON snapshot
- Merges GPS-tagged networks across runs (growing map)
- Detects “no-GPS” sessions gracefully
- Generates:
  - `data/stats/summary.json`
  - Channel and encryption CSVs
  - Timestamped GeoJSON snapshots
- Leaflet map with:
  - Type / Signal coloring modes  
  - Filter panel (SSID, type, min signal)  
  - Marker clustering for large datasets

---

## 🧩 Repository Layout

wardrive/
├─ scripts/build_map.sh # main orchestrator
├─ make_map.py # builds interactive map
├─ parse_netxml.py # legacy .netxml → CSV + GeoJSON
├─ csv_to_geojson.py # Wigle CSV → GeoJSON
├─ configs/kismet_logging.conf # Kismet logging template
├─ data/
│ ├─ stats/
│ └─ snapshots/
└─ logs/kismet/wardrive/


---

## ⚙️ Installation

**Debian / Kali / Ubuntu**

```bash
sudo apt update
sudo apt install -y kismet kismet-logtools jq python3
