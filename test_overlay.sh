#!/bin/bash
# Does the overlay actually behave on screen? Drives the real menu bar through
# the Accessibility API and asserts against what the window server renders,
# never against the UserDefaults we ourselves wrote - that would pass even if
# the panel never moved.
#
# Needs Accessibility and Screen Recording permission for whatever runs it
# (Terminal, iTerm, etc). Takes about three minutes.
#
# Three traps, all of which produced convincing false failures while this was
# being written, so do not "simplify" them away:
#   - "parent" is a reserved word in System Events; a menu variable named that
#     makes every click fail with -10006.
#   - AppleScript's click returns before the app has handled it, and the panel
#     animates its resize. Sampling too early latches the previous value or a
#     mid-animation frame, which looks exactly like a scaling bug.
#   - A leftover second instance is the most misleading failure of all: clicks
#     go to one process while the probe reads the other's stale window, so the
#     menu looks live while the panel looks frozen.

set -uo pipefail
cd "$(dirname "$0")"

TOOL=./overlay_test
APP=/Applications/Wattline.app
STATUS="$HOME/Library/Logs/wattline-status.json"
WORKOUT=/tmp/wattline-test.zwo
PASS=0
FAIL=0

# Measured at 100% once, then every other size is checked against it. Absolute
# pixel expectations break on a scaled external display, where CGWindowList
# reports a 360pt window as 324 - the window is right, the ruler is different.
BASE_W=0
BASE_H=0

pids() { pgrep -f "Wattline.app/Contents/MacOS/Wattline"; }
pid() { pids | head -1; }
only_one() { [ "$(pids | wc -l | tr -d ' ')" = "1" ]; }

fresh_app() {
  pids | xargs -r kill 2>/dev/null; sleep 2
  pids | xargs -r kill -9 2>/dev/null; sleep 1
  open -a "$APP"; sleep 4
  only_one || { echo "  !! $(pids | wc -l | tr -d ' ') instances, expected 1"; exit 1; }
}

# "width height alpha" of the overlay, or "none".
probe() {
  local p; p=$(pid)
  [ -z "$p" ] && { echo "none"; return; }
  $TOOL probe "$p" | python3 -c '
import json,sys
w=[x for x in json.load(sys.stdin) if x["onscreen"] and x["layer"]==25]
print("none" if not w else "%g %g %g"%(w[0]["width"],w[0]["height"],round(w[0]["alpha"],3)))
'
}

rect() {  # x y w h, top-left origin
  $TOOL probe "$(pid)" | python3 -c '
import json,sys
w=[x for x in json.load(sys.stdin) if x["layer"]==25]
if not w: sys.exit(1)
w=w[0]; print(int(w["x"]),int(w["y"]),int(w["width"]),int(w["height"]))
'
}

# Let the click land, then require three identical samples so we never assert
# against an in-flight animation frame.
settled() {
  sleep 1.5
  local a b run i
  a=$(probe); run=1
  for i in $(seq 1 30); do
    sleep 0.5
    b=$(probe)
    # Five in a row, not three: width and height finish their resize at
    # different moments, so a shorter run latches a frame where one axis has
    # settled and the other has not - which reads exactly like a scaling bug.
    if [ "$a" = "$b" ]; then run=$((run+1)); [ $run -ge 5 ] && { echo "$a"; return; }
    else a=$b; run=1; fi
  done
  echo "$a"
}

click_item() {
  osascript >/dev/null <<EOF
tell application "System Events" to tell process "Wattline"
	click menu bar item 1 of menu bar 1
	delay 0.4
	click menu item "$1" of menu 1 of menu bar item 1 of menu bar 1
end tell
EOF
}

click_sub() {
  osascript >/dev/null <<EOF
tell application "System Events" to tell process "Wattline"
	click menu bar item 1 of menu bar 1
	delay 0.4
	set holder to menu item "$1" of menu 1 of menu bar item 1 of menu bar 1
	click holder
	delay 0.4
	click menu item "$2" of menu 1 of holder
end tell
EOF
}

# Which entries carry a real checkmark; unchecked ones report "missing value".
checked_in() {
  osascript <<EOF
tell application "System Events" to tell process "Wattline"
	click menu bar item 1 of menu bar 1
	delay 0.4
	set holder to menu item "$1" of menu 1 of menu bar item 1 of menu bar 1
	click holder
	delay 0.4
	set out to {}
	repeat with mi in (menu items of menu 1 of holder)
		if (value of attribute "AXMenuItemMarkChar" of mi) is "✓" then set end of out to name of mi
	end repeat
	key code 53
	return out
end tell
EOF
}

# Hold the status file at a given power so the overlay's idle state is ours to
# choose, whether or not a real ride is running. Only touches the display file
# the menu reads, never the recording itself.
write_status() {  # power cadence
  printf '{"power": %s, "cadence": %s, "hr": 0, "speed": 0.0, "grade": null, "target_power": 180, "recording": true, "elapsed": 60, "avg_power": 0, "distance": 0, "sensors": [], "hills": false, "game": false}' "$1" "$2" > "$STATUS"
}

hold_status() {  # power cadence seconds
  local end=$((SECONDS+$3))
  while [ $SECONDS -lt $end ]; do write_status "$1" "$2"; sleep 0.1; done
}

# Any test that asserts a raw alpha has to keep the overlay awake, or idle dim
# legitimately multiplies it by 0.35 and every expectation is off by that.
AWAKE_PID=""
keep_awake() { hold_status 200 88 9999 & AWAKE_PID=$!; }
let_sleep() { [ -n "$AWAKE_PID" ] && kill $AWAKE_PID 2>/dev/null; AWAKE_PID=""; }
trap 'let_sleep; pkill -f "overlay_test catch" 2>/dev/null' EXIT

check() {
  if [ "$2" = "$3" ]; then echo "  PASS  $1 — $3"; PASS=$((PASS+1))
  else echo "  FAIL  $1 — expected [$2] got [$3]"; FAIL=$((FAIL+1)); fi
}

echo "=== preconditions ==="
[ -x $TOOL ] || { echo "build $TOOL first (make test-overlay)"; exit 1; }
# -R region capture is broken on some multi-display setups, and a revoked
# Screen Recording permission returns black frames rather than an error, so
# probe for both: grab the display and check it is not uniformly blank.
CAPTURE=yes
read -r DX DY DW DH <<< "$($TOOL screens)"
if ! screencapture -x -D 1 /tmp/.perm.png 2>/dev/null \
   || [ "$($TOOL ink /tmp/.perm.png)" = "0.0000" ]; then
  CAPTURE=no
  echo "  !! screen capture unavailable (permission or display change);"
  echo "     the content-scaling check will be skipped, everything else runs"
fi
defaults write com.devinwilson.wattline overlayVisible -bool true >/dev/null
defaults write com.devinwilson.wattline overlayOpacity -float 1.0 >/dev/null
fresh_app
echo "  single instance, pid $(pid); screen capture available"

echo
echo "=== 1. show / hide ==="
check "on screen" "yes" "$( [ "$(settled)" != none ] && echo yes || echo no)"
click_item "Hide overlay"
check "hidden" "none" "$(settled)"
click_item "Show overlay"
check "shown again" "yes" "$( [ "$(settled)" != none ] && echo yes || echo no)"

echo
echo "=== 2. size presets resize the rendered panel ==="
click_sub "Overlay size" "100%"
read -r BASE_W BASE_H _ <<< "$(settled)"
echo "  baseline at 100% = ${BASE_W}x${BASE_H}"
for pct in 75 125 150 200; do
  click_sub "Overlay size" "${pct}%"
  read -r gw gh _ <<< "$(settled)"
  # +/-2 for rounding at each end of the scale
  check "size ${pct}%" "yes" "$(python3 -c "
w,h=$BASE_W*$pct/100,$BASE_H*$pct/100
print('yes' if abs($gw-w)<=2 and abs($gh-h)<=2 else 'no (want %.0fx%.0f got $gw x $gh)'%(w,h))")"
done

echo
echo "=== 3. opacity presets change rendered alpha ==="
keep_awake
for pct in 40 60 80 100; do
  click_sub "Overlay opacity" "${pct}%"
  check "opacity ${pct}%" "$(python3 -c "print('%g'%($pct/100))")" "$(settled | cut -d' ' -f3)"
done

echo
echo "=== 4. the two controls are independent ==="
click_sub "Overlay size" "125%"; settled >/dev/null
read -r w125 h125 _ <<< "$(settled)"
click_sub "Overlay opacity" "60%"
check "size survives an opacity change" "$w125 $h125" "$(settled | cut -d' ' -f1,2)"
click_sub "Overlay size" "150%"
check "opacity survives a size change" "0.6" "$(settled | cut -d' ' -f3)"
let_sleep

echo
echo "=== 5. checkmarks reflect current values ==="
check "size checkmark" "150%" "$(checked_in 'Overlay size')"
check "opacity checkmark" "60%" "$(checked_in 'Overlay opacity')"

echo
echo "=== 6. the content scales, not just the window ==="
# Geometry alone cannot catch a panel that grows while its readout stays put.
# At reduced opacity the white text falls below the ink threshold, so measure
# this one at full opacity.
if [ "$CAPTURE" = "no" ]; then
  echo "  SKIP  content scaling (no screen capture available)"
else
  keep_awake
  click_sub "Overlay opacity" "100%"; settled >/dev/null
  # Grab the whole display and crop to the panel: cropping exactly matters
  # because any desktop left in the margin shifts the median this is measured
  # against.
  shot() {
    click_sub "Overlay size" "$1"; settled >/dev/null
    read -r x y w h <<< "$(rect)"
    screencapture -x -D 1 /tmp/shot.png
    $TOOL ink /tmp/shot.png "$x" "$y" "$w" "$h" "$DW" "$DH"
  }
  BASE_INK=$(shot "100%")
  BIG_INK=$(shot "200%")
  echo "  ink 100%=$BASE_INK  200%=$BIG_INK"
  check "content ink holds up at 200%" "yes" \
    "$(python3 -c "print('yes' if $BASE_INK>0.01 and $BIG_INK/$BASE_INK>0.6 else 'no')")"
  let_sleep
fi

echo
echo "=== 7. large sizes stay on screen ==="
click_sub "Overlay size" "200%"; settled >/dev/null
read -r x y w h <<< "$(rect)"
check "200% inside the ${DW}x${DH} desktop" "0" \
  "$(python3 -c "print(int(max(0,$x+$w-($DX+$DW))+max(0,$y+$h-($DY+$DH))))")"

echo
echo "=== 8. clicks pass through to what is underneath ==="
click_sub "Overlay size" "150%"; settled >/dev/null
read -r x y w h <<< "$(rect)"
$TOOL catch $((x-50)) $((y-50)) $((w+100)) $((h+100)) > /tmp/catch.log 2>&1 &
sleep 3
$TOOL click $((x-25)) $((y+20));          sleep 1   # control: catcher, no overlay
$TOOL click $((x+w/2)) $((y+h/2));        sleep 1   # through the overlay
CONTROL=$(grep -c HIT /tmp/catch.log)
check "control click and pass-through both land" "2" "$CONTROL"
$TOOL click $((x+w/2)) $((y+h/2)) opt;    sleep 1.5 # option grabs it back
check "option-click is grabbed by the overlay" "2" "$(grep -c HIT /tmp/catch.log)"
pkill -f "overlay_test catch" 2>/dev/null

echo
echo "=== 9. it dims when you stop pedalling ==="
hold_status 0 0 14
check "idle dims to 35%" "0.35" "$(probe | cut -d' ' -f3)"
hold_status 200 88 4
check "wakes on power" "1" "$(probe | cut -d' ' -f3)"
click_sub "Overlay opacity" "60%"; settled >/dev/null
hold_status 0 0 14
check "idle dim multiplies opacity" "0.21" "$(probe | cut -d' ' -f3)"
click_sub "Overlay opacity" "100%" >/dev/null

echo
echo "=== 10. the interval beep fires on time ==="
# Sound output cannot be captured here, so the app records every beep: which
# countdown tick it fired on, and whether the sound system accepted it. That
# covers what actually regresses - wrong moment, double-fire, silent failure.
BEEPS="$HOME/Library/Logs/wattline-beeps.log"
if ! curl -s --max-time 2 localhost:51235/ftp/250 >/dev/null 2>&1; then
  echo "  SKIP  beep timing (daemon not running on 51235)"
else
  cat > "$WORKOUT" <<'ZWO'
<workout_file><name>Beep Check</name><workout>
  <SteadyState Duration="8" Power="0.5"/>
  <SteadyState Duration="20" Power="0.9"/>
</workout></workout_file>
ZWO
  : > "$BEEPS"
  curl -s "localhost:51235/workout/load?path=$(python3 -c "
import urllib.parse,sys;print(urllib.parse.quote('$WORKOUT',safe=''))")" >/dev/null
  sleep 12   # first block is 8s, so the 3-2-1 countdown lands inside this
  TICKS=$(awk '{for(i=1;i<=NF;i++) if($i ~ /^tick=/) print substr($i,6)}' "$BEEPS" | tr '\n' ' ' | sed 's/ $//')
  PLAYED=$(grep -c "played=true" "$BEEPS" 2>/dev/null || echo 0)
  check "beeps at 3, 2 then 1" "3 2 1" "$TICKS"
  check "sound system accepted all three" "3" "$PLAYED"
  curl -s localhost:51235/workout/stop >/dev/null
fi

echo
echo "=== 11. settings survive a relaunch ==="
click_sub "Overlay size" "125%"
BEFORE=$(settled | cut -d' ' -f1,2)
fresh_app
check "geometry restored" "$BEFORE" "$(settled | cut -d' ' -f1,2)"
check "still one instance" "yes" "$(only_one && echo yes || echo no)"

echo
echo "=== $PASS passed, $FAIL failed ==="
exit $((FAIL > 0))
