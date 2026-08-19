# Wattline

Your bike's numbers, floating over whatever you are watching. On macOS, from
Bluetooth sensors, with no ANT+ dongle.

Two halves that work independently:

- **The overlay** — an always-on-top readout of power, cadence, heart rate and
  speed that sits over Netflix, YouTube, a game, anything, including fullscreen
  video. Load a `.zwo` workout and it counts you into each interval.
- **The bridge** — makes those same sensors work inside
  [GT Bike V](https://www.gtbikev.com), the GTA V cycling mod, which cannot see
  Bluetooth from inside CrossOver.

Ride with just the overlay if you have no interest in GTA V. Nothing about the
overlay needs the game, and it does not care what trainer app, if any, you are
also running.

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

Everything else lives in **Settings…** in the menu bar:

- Size and opacity sliders (also under `Overlay size` / `Overlay opacity`)
- Which numbers to show: cadence, heart rate, speed, distance, elapsed, grade.
  Power is always shown. Speed and distance hide themselves during a workout,
  where they mean nothing.
- Workout graph on/off, interval beep on/off, dim-when-idle on/off

It dims to 35% when you stop pedalling and comes back the moment you start, so
it is not a bright rectangle burning into your show during a rest.

## Workouts

Load any Zwift `.zwo` file: menu > `Load workout…`. Set your FTP first
(`Set FTP…`) — the file stores percentages, not watts.

While a workout runs the overlay shows the target, the time left in the block,
and what is coming next. If the trainer supports FTMS target power, the bridge
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

## Why the bridge exists

GT Bike V reads bike sensors two ways, and both are dead inside CrossOver:

- `BLE_Receiver.dll` uses WinRT `BluetoothLEDevice`. Wine has no Bluetooth
  stack on macOS, so it finds nothing.
- `ANT_Receiver.dll` drives a USB stick through `DSI_SiUSBXp_3_1.DLL` (SiLabs)
  or `libusb0.dll`, enumerating `USB\VID_0FCF&PID_10*`. CrossOver has no USB
  driver stack, so buying a dongle probably would not have helped either.

Your Mac, meanwhile, talks to the sensors perfectly over CoreBluetooth. So the
bridge reads them natively and hands the data to the game as a **fake ANT+
stick**: a drop-in `DSI_SiUSBXp_3_1.DLL` that answers "yes, one stick here" and
pipes its serial stream over TCP to a Python emulator speaking the ANT message
protocol.

    bike sensor --BLE--> macOS (bike_ble.py) --> ant_stick.py
                                                     |
                                                 TCP 51234
                                                     |
    GTA V / GT Bike V <-- ANT_Receiver.dll <-- DSI_SiUSBXp_3_1.DLL (shim)

## Install

    make agent

That is the whole setup, once, and the only command you ever have to type. It
builds everything, installs `Wattline.app`, starts the bridge, sets it to run at
login, and installs the fake dongle into the CrossOver bottle if you have one.

**macOS will ask whether Wattline can use Bluetooth. Say yes.** Bluetooth access
is granted per application identity, and if you decline it there is no second
prompt and no error — scanning simply hangs forever and finds nothing. If you
already said no, undo it in System Settings > Privacy & Security > Bluetooth.

Then turn the trainer on and ride. For GTA V, pair inside GT Bike V as if you
had an ANT+ stick: the bridge appears as a smart trainer (device 1117) plus
speed+cadence (1121), speed (1123), cadence (1122), power (1111) and heart rate
(1120), depending on what your sensors actually report.

Requires macOS 13+, Python 3.10+, and a Bluetooth trainer or sensor. The GTA V
half additionally needs CrossOver and GT Bike V; nothing about the overlay does.

## The menu bar is the interface

Everything lives under the 🚲 in the menu bar. GTA V is optional — the trainer
side works on its own:

    🚲 212 W · 31.4 km/h · 148 bpm · +6.5% grade
    ● Recording  24 min · 208W avg · 12.4 km
    Holding 200W
    Elite Suito: 2ad2, 2ad9 (control) · hills on
    Game connected
    Stop ride and upload to Strava
    Hold a power target  >  100..300 W, or release
    Load workout…           - any Zwift .zwo file
    Hide overlay
    Overlay size            >  75 .. 200%
    Overlay opacity         >  40 .. 100%
    Hide graph
    Set FTP…                - workouts are percentages, so this has to be right
    Settings…               - fields, toggles, sliders, and what ⌥ does
    Check my sensors…       - live read-out, says whether hills will work
    Past rides
    Open log
    Quit

With a workout loaded, `Load workout…` is replaced by `Pause workout`,
`Skip this block` and `Stop workout`.

Red 🚲 means the bridge died. Everything is one click.

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

Nothing. The bridge sits on a socket and only starts scanning Bluetooth when
GTA V connects, then stops again 90 seconds after you quit. A permanent BLE
scan would drain the battery for no reason.

    make status           # same thing from the terminal

## Checks

    make test             # bridge behaves like an ANT+ stick (no game, no sensor)
    make test-overlay     # drives the real menu bar, asserts against the screen
    make check-bottle     # Windows code inside the bottle reaches the bridge
    venv/bin/python plan.py       # .zwo parsing and zone maths
    venv/bin/python bike_ble.py   # live read-out of your actual sensors

`make check-bottle` needs the bridge running. `make fake` runs it in the
foreground with a simulated rider (180W, 90rpm, 142bpm, 30kph), useful for
testing without a bike — stop the agent first (`make agent-off`) so the port is
free.

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

## If the game still finds no sensor

The shim logs every call to `C:\ant_shim.log` inside the bottle. Launch the
game, then read it:

    cat "$HOME/Library/Application Support/CrossOver/Bottles/Steam-2/drive_c/ant_shim.log"

- **File is empty or missing**: GT Bike V never loaded the shim, so it went for
  `libusb0.dll` instead. Same trick works there, it is just a different set of
  exports to fake.
- **`SI_GetNumDevices -> 0`**: the bridge was not running when the game started.
- **Calls stop after `SI_Open`**: the ANT library wants something the emulator
  answers wrongly. The bytes it sent are in the `ant_stick.py` output.

## Hills

The bridge works both ways. GT Bike V sends the slope of whatever road you are
riding as an ANT+ FE-C track resistance page; the bridge decodes it and writes
it to the trainer as an FTMS indoor bike simulation command, so Los Santos
terrain becomes real resistance.

    game: "this road is +6.5%"  --FE-C-->  bridge  --FTMS-->  trainer brakes

ERG workouts come across too: a target power page becomes an FTMS target power
write. `TrainerDifficulty` in `GTBikeVConfig.ini` scales how much of each climb
gets sent, 0 to 100.

Grade changes are pushed at most four times a second and only when the value
moves, because control points are slow and trainers stutter if you hammer them.

## Not done

- **Power meters.** Broadcast, but untested against a real one. If the bike
  only reports speed, set `PowerCurve` in `GTBikeVConfig.ini` so the mod
  estimates watts from speed.
- **Trainers that are not FTMS.** Older Wahoo and Tacx units use proprietary
  BLE control. Data would still flow up; resistance would not come back down.
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
which belong to their respective owners: GT Bike V, Rockstar Games, Zwift,
Strava, Wahoo, Elite, Tacx, Garmin, ANT+, CodeWeavers/CrossOver. This project
interoperates with GT Bike V and reads Zwift's `.zwo` file format; it contains
no code from either.

"Wattline" is not a registered trademark of this project. A German energy
company trades under a similar name in an unrelated field.
