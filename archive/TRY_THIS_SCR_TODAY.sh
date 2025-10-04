# A) Confirm gpsd is giving you a fix (2 or 3)
gpspipe -w -n 10 | jq -r 'select(.class=="TPV") | .mode' | tail -1

# B) Start capture (script will now wait up to 180s for the fix)
./scripts/wardrive.sh start wlan1

# C) Move around for 2–5 minutes so packets get geo-tagged
# (You can tail logs and look for new Wi-Fi devices)
tail -f ~/wardrive/logs/kismet/wardrive/kismet_run_*.log

# D) Stop and build the map
./scripts/wardrive.sh stop
./scripts/build_map.sh
