#!/usr/bin/env python3
import csv, json, sys

if len(sys.argv) != 3:
    print(f"Usage: {sys.argv[0]} input.csv output.geojson")
    sys.exit(1)

infile, outfile = sys.argv[1], sys.argv[2]
features = []

def to_float(val):
    if val is None:
        return None
    s = str(val).strip().lower().replace("dbm", "").replace("-", "-")
    if s in {"", "none", "nan", ""}:
        return None
    try:
        return float(s)
    except:
        try:
            return float(s.replace(",", "."))
        except:
            return None

with open(infile, newline='', encoding="utf-8") as f:
    _ = f.readline()  # skip WigleWifi-1.4 metadata line
    reader = csv.DictReader(f)
    for row in reader:
        lat = row.get("CurrentLatitude") or row.get("Latitude")
        lon = row.get("CurrentLongitude") or row.get("Longitude")
        if not lat or not lon:
            continue
        try:
            lat = float(lat)
            lon = float(lon)
        except:
            continue
        if abs(lat) < 1e-4 and abs(lon) < 1e-4:
            continue

        sig = to_float(row.get("RSSI"))

        feature = {
            "type": "Feature",
            "geometry": {"type": "Point", "coordinates": [lon, lat]},
            "properties": {
                "SSID": row.get("SSID", "hidden"),
                "BSSID": row.get("MAC", ""),
                "Channel": row.get("Channel", ""),
                "Signal": sig,
                "Encryption": row.get("AuthMode", "")
            }
        }
        features.append(feature)

geojson = {"type": "FeatureCollection", "features": features}
with open(outfile, "w", encoding="utf-8") as out:
    json.dump(geojson, out, indent=2)

print(f"Saved {len(features)} features to {outfile}")
