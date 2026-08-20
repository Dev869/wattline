# Wattline

Your bike's numbers, floating over whatever you are watching. On macOS, from
Bluetooth sensors, with nothing to pair and nothing to plug in.

An always-on-top readout of power, cadence, heart rate and speed that sits over
Netflix, YouTube, a game, anything, including fullscreen video. Load a `.zwo`
workout and it counts you into each interval, holding the wattage on the trainer
for you. Stop the ride and it goes to Strava.

It does not care what else you are running. Ride along to a film, or to another
trainer app entirely — Wattline reads the same sensors and stays out of the way.

    ┌──────────────────────────────────┐
    │  180 W        95 rpm   142 bpm   │   ← floats over anything
    │  30.0 km/h                       │
    └──────────────────────────────────┘

## The overlay

It is a non-activating panel at the status-bar window level, so it stays on top
of fullscreen video without stealing focus or pausing playback. Clicks pass
straight through it — the overlay is never in your way, and you can scrub
Netflix through the middle of it.

**Hold ⌥ to grab it.** Drag anywhere to move, drag the bottom-right corner to
resize. Let go of ⌥ and it goes back to being scenery. That gesture is the whole
interface; there is no chrome to hunt for and no window to accidentally focus.

Everything else lives in **Settings…** in the menu bar, two columns of grouped
cards rather than a list you scroll:

- **Overlay** — show/hide, size and opacity sliders, workout graph, dim-when-idle
- **Show these numbers** — cadence, heart rate, speed, distance, elapsed.
  Power is always shown. Speed and distance hide themselves during a workout,
  where they mean nothing.
- **Rider** — your FTP, the one number every workout file is measured against
- **Workouts** — the interval beep
- **Sensors** — every cycling device in earshot, live: what it offers and
  whether it is connected
- **Rides** — whether Strava is hooked up, and a way into the saved `.tcx` files

It dims to 35% when you stop pedalling and comes back the moment you start, so
it is not a bright rectangle burning into your show during a rest.

## Workouts

Load any Zwift `.zwo` file: menu > `Load workout…`. Set your FTP first
(`Set FTP…`) — the file stores percentages, not watts.

While a workout runs the overlay shows the target, the time left in the block,
and what is coming next. If the trainer supports FTMS target power, Wattline
holds the wattage for you; otherwise the number is a target to chase.

**Before each interval you get a 3-2-1 countdown**: three beeps, one per second,
and the panel edge holds amber for the last three seconds. It is held, not
flashing — flashing red at the rate this would need can trigger photosensitive
seizures, and every trainer app that has solved this problem solved it with
audio plus a steady colour. The beep can be turned off; the colour cannot,
because with the beep off it is the only warning left.

The graph at the bottom is the next two minutes and the last one, coloured by
power zone, with a fixed "now" line the blocks scroll through. It sits behind
the numbers rather than beside them, so turning it on does not make the overlay
any bigger. Toggle it in Settings, or `Show/Hide graph` in the menu.

## Install

    make agent

That is the whole setup, once, and the only command you ever have to type. It
builds everything, installs `Wattline.app`, starts it, and sets it to run at
login.

**macOS will ask whether Wattline can use Bluetooth. Say yes.** Bluetooth access
is granted per application identity, and if you decline it there is no second
prompt and no error — scanning simply hangs forever and finds nothing. If you
already said no, undo it in System Settings > Privacy & Security > Bluetooth.

Then turn the trainer on and ride. There is nothing to pair: Wattline scans the
whole time it is running and connects to the first cycling sensor that answers,
so switching the trainer on is the entire ritual. Until something answers the
menu says `Searching for sensors…`, and the Sensors group in Settings lists
every cycling device it can hear as it hears it — name, what each one offers,
and whether it is connected — so a scan that is finding nothing looks different
from a scan that is broken. If you have two bikes in the room, start the daemon
with `--name` and part of the name you want (`--name Suito`).

Requires macOS 13+, Python 3.10+, and a Bluetooth trainer, power meter, cadence
sensor or heart rate strap. Any mixture of those; it reads whatever answers.

## ANT+

No Mac can receive ANT+ — the built-in radio does Bluetooth, Wi-Fi and Thread,
and its firmware is closed. Most sensors made since about 2016 broadcast both
ANT+ and Bluetooth, so check Settings first; if yours is listed there, none of
this matters.

For genuinely ANT+-only kit, something else can be the aerial. Put a dongle in
a Raspberry Pi or any non-Mac machine and run the relay:

    pip install openant
    relay/wattline-relay.py --host <your-mac>.local

then start Wattline with `--ant-relay-lan` so it will listen to that machine.
Relayed sensors appear in the Sensors list beside the Bluetooth ones. The wire
format is nine bytes a packet, so writing a relay for some other aerial is
short work. `relay/wattline-relay.py --fake` sends a simulated rider if you
want to see the path working before buying anything.

[docs/ant-without-a-stick.md](docs/ant-without-a-stick.md) has the full
reasoning, what was ruled out, and what to try if you want to go further.

## The menu bar is the interface

Everything lives under the 🚲 in the menu bar:

    🚲 212 W · 31.4 km/h · 148 bpm
    ● Recording  24 min · 208W avg · 12.4 km
    Holding 200W
    Elite Suito: 2ad2, 2ad9 (control) · holds a target
    Stop ride and upload to Strava
    Hold a power target  >  100..300 W, or release
    Load workout…           - any Zwift .zwo file
    Hide overlay
    Overlay size            >  75 .. 200%
    Overlay opacity         >  40 .. 100%
    Hide graph
    Set FTP…                - workouts are percentages, so this has to be right
    Settings…               - toggles, sliders, FTP, and what the scan can hear
    Past rides
    Open log
    Quit

With a workout loaded, `Load workout…` is replaced by `Pause workout`,
`Skip this block` and `Stop workout`.

Red 🚲 means the daemon died. Everything is one click.

## ERG workouts and Strava

Pick a wattage from the menu and the trainer holds it - that is standard FTMS
target power, so the trainer does the work of holding it, not us.

"Start ride" records power, cadence, heart rate, speed and distance once a
second. "Stop ride" writes a TCX into `~/Documents/Wattline Rides` and uploads it
to Strava. Rides are always saved locally first, so a failed upload never costs
you the ride.

Strava needs connecting once, and only you can do it because it is your
account: menu > Connect Strava, or `venv/bin/python strava.py setup`. Create an
app at https://www.strava.com/settings/api with callback domain `localhost`,
paste the Client ID and Secret, approve in the browser. The refresh token is
stored in `~/.config/wattline/strava.json` (mode 600) and keeps working.

The buttons are plain HTTP against the daemon, so they work from a terminal too:

    curl -s localhost:51235/power/200
    curl -s localhost:51235/ride/start
    curl -s localhost:51235/ride/stop
    curl -s localhost:51235/ftp/250
    curl -s "localhost:51235/workout/load?path=/path/to/session.zwo"
    curl -s localhost:51235/workout/pause     # resume, skip, stop

## What it does when you are not riding

Listens. It scans for sensors the whole time it is running, so switching the
trainer on is all it takes — a sensor nobody is looking for is a sensor that
will never be found. Quit from the menu and the scan stops with it.

    make status           # is it up, is it listening, last few log lines

## Checks

    make test             # scans on its own, and reports what it hears
    make test-overlay     # drives the real menu bar, asserts against the screen
    venv/bin/python plan.py       # .zwo parsing and zone maths
    venv/bin/python bike_ble.py   # live read-out of your actual sensors

`make fake` runs the daemon in the foreground with a simulated rider (180W,
90rpm, 142bpm, 30kph), useful for working on the overlay without a bike — stop
the agent first (`make agent-off`) so the port is free.

`make test-overlay` takes about three minutes and needs Accessibility and Screen
Recording permission for whatever terminal runs it. It drives the menus for
real, so it takes over the pointer while it runs. It never asserts against the
preferences it just wrote — only against what the window server actually
renders, since checking our own UserDefaults would pass even if the panel never
moved.

## Why there is an .app in here

macOS grants Bluetooth access per application identity. A LaunchAgent running
python has none, so CoreBluetooth silently refuses to power on and every scan
hangs forever with no error. `Wattline.app` is a two-line wrapper that
exists only to give TCC something to grant. If macOS ever asks whether
Wattline can use Bluetooth, say yes.

## Not done

- **Power meters.** Read, but untested against a real one.
- **Trainers that are not FTMS.** Older Wahoo and Tacx units use proprietary
  BLE control. Their numbers would still be read; a workout could not set the
  resistance, so the target would be yours to chase.
- **Unsigned builds.** There is no Developer ID signature, so the first launch
  needs right-click > Open, or `xattr -d com.apple.quarantine`.
- **One display at a time.** The overlay handles multiple displays fine; the
  test suite's screen-capture checks do not, and skip themselves.

## Contributing

Bug reports want three things: what your trainer is, what `make status` says,
and the last few lines of `~/Library/Logs/wattline.log`. Sensor bugs are
otherwise unfixable remotely — every trainer lies about a different part of the
BLE spec.

Patches welcome. Run `make test` and `make test-overlay` before opening a PR.
Non-trivial logic leaves a self-check behind (`python plan.py` style); there is
no test framework here and there does not need to be one.

## Licence and names

MIT — see [LICENSE](LICENSE).

Not affiliated with, endorsed by, or connected to any of the following, all of
which belong to their respective owners: Zwift, Strava, Wahoo, Elite, Tacx,
Garmin. This project reads Zwift's `.zwo` file format; it contains no code from
Zwift.

"Wattline" is not a registered trademark of this project. A German energy
company trades under a similar name in an unrelated field.
