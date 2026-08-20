#!/bin/bash
# SwiftBar plugin: the same menu as the app, for anyone who lives in SwiftBar.
# Installed to ~/.config/swiftbar by `make agent`.

# <xbar.title>Wattline</xbar.title>
# <xbar.desc>Live bike numbers, ERG workouts and Strava upload</xbar.desc>

ROOT="$HOME/wattline"
LOG="$HOME/Library/Logs/wattline.log"
STATUS="$HOME/Library/Logs/wattline-status.txt"
RIDES="$HOME/Documents/Wattline Rides"
AGENT="com.devinwilson.wattline"
API="http://127.0.0.1:51235"

# Every button is a one-line curl at the daemon.
cmd() { echo "$1 | bash=/usr/bin/curl param1=-s param2=$API$2 terminal=false refresh=true"; }

if ! pgrep -f "daemon.py" >/dev/null; then
  echo "🚲✗ | color=red"
  echo "---"
  echo "Wattline is not running"
  echo "Start it | bash=/bin/launchctl param1=kickstart param2=gui/$UID/$AGENT terminal=false refresh=true"
  echo "Open log | bash=/usr/bin/open param1=$LOG terminal=false"
  exit 0
fi

# The daemon keeps this current: first line is the menu bar title, rest is menu.
if [ -f "$STATUS" ]; then
  cat "$STATUS"
else
  echo "🚲"
  echo "---"
  echo "Starting up..."
fi

echo "---"
if grep -q "● Recording" "$STATUS" 2>/dev/null; then
  cmd "Stop ride and upload to Strava" "/ride/stop"
else
  cmd "Start ride" "/ride/start"
fi

echo "Hold a power target"
for watts in 100 120 140 160 180 200 220 250 280 300; do
  cmd "--${watts} W" "/power/$watts"
done
cmd "--Release (no target)" "/power/off"

echo "---"
if [ -f "$HOME/.config/wattline/strava.json" ]; then
  echo "Strava connected | color=gray"
else
  echo "Connect Strava | bash=/bin/bash param1=-lc param2=\"cd '$ROOT' && venv/bin/python strava.py setup\" terminal=true"
fi
echo "Past rides | bash=/usr/bin/open param1=\"$RIDES\" terminal=false"
echo "Restart Wattline | bash=/bin/launchctl param1=kickstart param2=-k param3=gui/$UID/$AGENT terminal=false refresh=true"
echo "Open log | bash=/usr/bin/open param1=$LOG terminal=false"
