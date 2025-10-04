#!/usr/bin/env python3
import sys, csv, json, xml.etree.ElementTree as ET
from pathlib import Path

def parse_netxml(path):
    root = ET.parse(path).getroot()
    rows, features = [], []

    for net in root.findall("wireless-network"):
        # Basic fields (defensive parsing)
        bssid = net.get("BSSID") or "unknown"
        ssid_el = net.find("SSID/essid")
        ssid = (ssid_el.text if ssid_el is not None else "hidden").strip() or "hidden"

        enc_el = net.find("SSID/encryption")
        enc = (enc_el.text if enc_el is not None else "unknown").upper()

        chan_el = net.find("channel")
        chan = chan_el.text if chan_el is not None else ""

        rssi_el = net.find("snr-info/last_signal_dbm")
        rssi = rssi_el.text if rssi_el is not None else ""

        # GPS (avg lat/lon generally best for per-network point)
        lat_el = net.find("gps-info/avg-lat")
        lon_el = net.find("gps-info/avg-lon")
        lat = lat_el.text if lat_el is not None else None
        lon = lon_el.text if lon_el is not None else None

        rows.append([ssid, bssid, enc, chan, lat, lon, rssi])

        if lat and lon:
            try:
                features.append({
                    "type": "Feature",
                    "geometry": {"type": "Point", "coordinates": [float(lon), float(lat)]},
                    "properties": {
                        "SSID": ssid, "BSSID": bssid, "Encryption": enc,
                        "Channel": chan, "Signal": rssi
                    }
                })
            except ValueError:
                pass

    return rows, {"type": "FeatureCollection", "features": features}

def main():
    if len(sys.argv) < 2:
        print("Usage: python3 parse_netxml.py /path/to/*.netxml")
        sys.exit(1)

    for arg in sys.argv[1:]:
        for p in sorted(Path().glob(arg) if any(x in arg for x in "*?[]") else [Path(arg)]):
            if not p.exists(): 
                print(f"Skip (not found): {p}")
                continue
            rows, geo = parse_netxml(p)
            csv_out = p.with_suffix(".csv")
            geo_out = p.with_suffix(".geojson")

            with open(csv_out, "w", newline="") as f:
                w = csv.writer(f)
                w.writerow(["SSID","BSSID","Encryption","Channel","Latitude","Longitude","Signal_dBm"])
                w.writerows(rows)

            with open(geo_out, "w") as f:
                json.dump(geo, f, indent=2)

            print(f"OK: {p.name} → {csv_out.name}, {geo_out.name} ({len(geo['features'])} points)")

if __name__ == "__main__":
    main()
