#!/usr/bin/env bash
set -euo pipefail
sudo killall gpsd || true
# Use the device you saw in dmesg (ttyACM0 from your output)
sudo gpsd /dev/serial0 -F /var/run/gpsd.sock
