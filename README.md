# 🛰️ WiMa — Wifi Mapper (Alpha)

WiMa (Wifi Mapper) is an end-to-end toolkit that converts Kismet logs into GeoJSON snapshots and an interactive Leaflet map.  
It is designed for **research, education, and authorized security testing** — providing a lightweight, repeatable way to visualize wireless network data.

> **Status:** Alpha — stable core pipeline (capture → parse → merge → map).  
> **License:** MIT  
> **Author:** JohanTheBlue

---

## 🚀 Features

- Automatically detects the latest Kismet database (`.kismet`)
- Converts data into timestamped GeoJSON snapshots
- Merges networks across multiple runs (accumulates GPS-known APs)
- Generates statistics:
  - `data/stats/summary.json`
  - `data/stats/channel_counts.csv`
  - `data/stats/encryption_counts.csv`
- Builds a fully interactive Leaflet map:
  - Two coloring modes (by *type* or *signal strength*)
  - Filters for SSID, signal level, and device type
  - Marker clustering for performance
- CLI helper targets via `Makefile`

---

## 🧩 Repository Layout

```

WiMa/
├─ scripts/build_map.sh          # main orchestrator
├─ make_map.py                   # builds interactive map
├─ parse_netxml.py               # legacy .netxml → CSV + GeoJSON
├─ csv_to_geojson.py             # Wigle CSV → GeoJSON
├─ configs/kismet_logging.conf   # Kismet logging template
├─ tools/anonymize_snapshot.py   # prepares sanitized public datasets
├─ data/
│  ├─ stats/
│  └─ snapshots/
├─ logs/kismet/wardrive/
├─ Makefile
└─ README.md

````

---

## ⚙️ Installation

**Debian / Ubuntu / Kali Linux**

```bash
sudo apt update
sudo apt install -y kismet kismet-logtools jq python3
````

Clone the repository:

```bash
git clone https://github.com/JohanTheBlue/WiMa.git
cd WiMa
```

(Optional) link Kismet config:

```bash
mkdir -p ~/.kismet
ln -sf $PWD/configs/kismet_logging.conf ~/.kismet/kismet_logging.conf
```

---

Nice catch — thanks for pasting `scripts/wardrive.sh`. That makes the README Quickstart a bit too generic — your repo already has a convenient wrapper to start/stop Kismet. I'll give you an updated **Quickstart** section (copy-paste ready) that replaces the simple `kismet` line with the `scripts/wardrive.sh` usage and explains the flow (start → roam → stop → build).

---

### What changed / why

Your `scripts/wardrive.sh`:

* handles directory checks and permissions,
* ensures `gpsd` is running,
* brings up the interface,
* starts Kismet headless with logs placed under `logs/kismet/wardrive`,
* writes a PID file so you can stop it cleanly.

So the README should direct users to use that script instead of invoking `kismet` manually.

---

## 🧭 Quickstart (recommended)

WiMa includes a helper script to manage headless Kismet runs: `scripts/wardrive.sh`.
This handles log directories, gpsd, interface bring-up, and clean stop/start.

### 1. Prepare (once)

Make sure `gpsd` and Kismet tools are available:
```bash
sudo apt update
sudo apt install -y kismet kismet-logtools gpsd gpsd-clients jq python3
````

(Optional) ensure the repo config is linked to your home:

```bash
mkdir -p ~/.kismet
ln -sf $PWD/configs/kismet_logging.conf ~/.kismet/kismet_logging.conf
```

### 2. Start a capture

Start Kismet headless via the provided wrapper. It will create logs under `logs/kismet/wardrive`.

```bash
# default interface is wlan1; pass a different iface as 2nd arg, e.g. wlan0
./scripts/wardrive.sh start [iface]

# example:
./scripts/wardrive.sh start wlan0
```

While Kismet runs, drive/walk around to collect beacons. The script will:

* ensure `gpsd` is running,
* wait briefly for GPS lock (configurable timeout in script),
* write Kismet logs with prefix in `logs/kismet/wardrive`,
* leave a PID file so you can stop it later.

### 3. Stop capture

When you're done capturing:

```bash
./scripts/wardrive.sh stop
```

This stops the Kismet process(s) started by the script and attempts to clean up monitor/helper processes.

### 4. Build the map & stats

After stopping Kismet (or while Kismet logs exist), build the GeoJSON snapshot and HTML map:

```bash
make map
make echo-path   # prints path to the latest generated HTML map
make open        # if your environment supports it
```

If you prefer a dry-run sanity check first:

```bash
make ci
```

---

### Notes & tips

* Interface: the script defaults to `wlan1`. Pass your interface as the second argument if you use `wlan0` or another name.
* GPS: `gpsd` is required for best results; the script will attempt to start/enable the system `gpsd` service. If you don't have GPS hardware, the pipeline will still work but may infer old GPS positions for APs.
* Permissions: starting Kismet and bringing interfaces up requires sufficient privileges. The script uses `sudo` for the necessary operations.
* Logs and outputs: raw `.kismet` DBs and PCAPs are kept under `logs/` (and your `.gitignore` should exclude them). `make map` reads those logs and writes sanitized snapshots into `data/snapshots/` and an HTML map into `logs/kismet/wardrive/` which is copied to `data/snapshots/` for convenience.

````

---

## 📊 Outputs

| Type           | Example Path                                      | Description                     |
| -------------- | ------------------------------------------------- | ------------------------------- |
| Stats JSON     | `data/stats/summary.json`                         | Aggregated totals, devices, APs |
| Channel CSV    | `data/stats/channel_counts.csv`                   | Channel distribution            |
| Encryption CSV | `data/stats/encryption_counts.csv`                | Open/WPA/WPA2 share             |
| GeoJSON        | `data/snapshots/networks_YYYYMMDD-HHMMSS.geojson` | Merged network dataset          |
| HTML Map       | `data/snapshots/networks_colored.html`            | Interactive Leaflet map         |

---

## 🧪 CLI Helpers

| Command          | Description                                         |
| ---------------- | --------------------------------------------------- |
| `make ci`        | Syntax & preflight checks                           |
| `make map`       | Full rebuild (Kismet → GeoJSON → HTML)              |
| `make stats`     | Update stats only                                   |
| `make open`      | Open the latest map (auto-detects available opener) |
| `make echo-path` | Print the path to the newest map                    |
| `make clean`     | Clear temporary outputs                             |
| `make setup`     | Create directories for first-time setup             |

---

## 🔒 Acceptable Use & Privacy

WiMa is for **passive**, lawful, and ethical use only.
By using this software, you agree to:

* **Not** access, probe, or interfere with networks you do not own or have explicit authorization to test.
* **Not** collect or share personally identifiable information (such as real MAC addresses, client devices, or precise timestamps) without informed consent.
* **Always** sanitize or anonymize data before public release using provided tools.

Example anonymization:

```bash
python3 tools/anonymize_snapshot.py \
  --input data/snapshots/networks_20251004-154342.geojson \
  --output docs/sample_sanitized.geojson \
  --hash-macs --drop-clients
```

This produces a safe-to-publish copy of your dataset for demos or research.

---

## 🤝 Contributing

Contributions are welcome!
Please read:

* [`CONTRIBUTING.md`](CONTRIBUTING.md)
* [`CODE_OF_CONDUCT.md`](CODE_OF_CONDUCT.md)
* [`SECURITY.md`](SECURITY.md)

All PRs must pass `make ci` before review.

---

## 📜 License

WiMa is licensed under the **MIT License**.
See the [`LICENSE`](LICENSE) file for details.

---

**Author / Maintainer:** JohanTheBlue
© 2025 WiMa Project — Wifi Mapper