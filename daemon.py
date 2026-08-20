"""The Wattline daemon: read the bike over Bluetooth, publish what it says.

Owns the BLE connection, the ride recorder, the workout runner and the little
localhost endpoint the menu bar app drives. It writes two files - a plain-text
status the menu prints verbatim, and the same numbers as JSON for the overlay -
and otherwise stays out of the way.

    python daemon.py            # needs a real sensor
    python daemon.py --fake     # a simulated 90rpm rider, for working on the UI
"""

import argparse
import asyncio
import json
import os
import time

import ant_relay
import bike_ble
import plan
import strava
import workout


STATUS_FILE = os.path.expanduser("~/Library/Logs/wattline-status.txt")
STATUS_JSON = os.path.expanduser("~/Library/Logs/wattline-status.json")
CONTROL_PORT = 51235


async def control_server(state, ride, log, live):
    """Tiny HTTP endpoint so the menu bar can drive a workout with one click.

    Hand-rolled rather than a framework: it serves five fixed paths and never
    faces anything but localhost.
    """

    async def handle(reader, writer):
        try:
            request = await asyncio.wait_for(reader.readline(), 5)
            path = request.decode(errors="replace").split(" ")[1] if b" " in request else "/"
            body = await route(path)
        except Exception as exc:
            body = f"error: {exc}"
        writer.write(
            b"HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n"
            + f"Content-Length: {len(body.encode())}\r\n\r\n".encode()
            + body.encode()
        )
        await writer.drain()
        writer.close()

    async def route(path):
        parts = [p for p in path.split("?")[0].split("/") if p]

        if parts[:1] == ["power"]:
            if parts[1] == "off":
                state.target_power = None
                log("erg: released")
                return "erg off"
            state.target_power = int(parts[1])
            log(f"erg: hold {state.target_power}W")
            return f"holding {state.target_power}W"

        if parts[:1] == ["workout"]:
            what = parts[1] if len(parts) > 1 else ""
            if what == "load":
                # The path arrives percent-encoded on the query string.
                from urllib.parse import unquote, urlparse, parse_qs
                want = parse_qs(urlparse(path).query).get("path", [""])[0]
                loaded = plan.load(unquote(want))
                live["plan"] = loaded
                loaded.start(state)
                log(f"workout: {loaded.name}, {loaded.total / 60:.0f} min")
                return f"loaded {loaded.name}"
            current = live.get("plan")
            if not current:
                return "no workout loaded"
            if what == "pause":
                current.pause(); return "paused"
            if what == "resume":
                current.resume(); return "resumed"
            if what == "skip":
                current.skip(); return "skipped"
            if what == "stop":
                current.stop(state); live["plan"] = None; return "stopped"
            return "unknown workout command"

        if parts[:1] == ["ftp"]:
            return f"ftp {plan.set_ftp(int(parts[1]))}"

        if parts[:2] == ["ride", "start"]:
            ride.start()
            log("ride: recording")
            return "recording"

        if parts[:2] == ["ride", "stop"]:
            if not ride.running:
                return "no ride running"
            ride.stop()
            state.target_power = None
            path = ride.save()
            mins, avg = ride.elapsed / 60, ride.avg_power
            log(f"ride: {mins:.0f} min, {avg:.0f}W avg, saved to {path}")
            if not strava.configured():
                return f"saved {path} (Strava not set up)"
            try:
                name = f"{mins:.0f} min indoor ride"
                url = await asyncio.to_thread(ride_upload, path, name)
                log(f"strava: {url}")
                return url
            except Exception as exc:
                log(f"strava upload failed: {exc}")
                return f"saved locally, upload failed: {exc}"

        return "unknown command"

    server = await asyncio.start_server(handle, "127.0.0.1", CONTROL_PORT)
    async with server:
        await server.serve_forever()


def ride_upload(path, name):
    return strava.upload(path, name=name, description="Recorded by wattline")


async def status_loop(state, live, ride=None):
    """Write what is happening, formatted for the menu bar to just print.

    Plain text on purpose: the menu bar script cats this file rather than
    parsing anything.
    """
    prev_crank = None
    cadence = 0
    # The menu bar app starts us and kills us on quit, but a hard kill of the
    # app leaves us orphaned holding the control port, and the next app adopts
    # that stale copy instead of starting a current one. Being reparented to
    # launchd is the tell. (Not a concern when launchd starts us directly: then
    # our parent is 1 from the first tick, and this only fires on a change.)
    parent = os.getppid()
    while True:
        if parent != 1 and os.getppid() != parent:
            print(time.strftime("%H:%M:%S"), "menu bar app gone, shutting down", flush=True)
            # ponytail: straight out, no unwinding. Raising from a background
            # task only gets us an asyncio "never retrieved" traceback, and
            # there is nothing to flush - the status files are rewritten every
            # tick and a ride is only ever saved on an explicit stop.
            os._exit(0)
        cur_crank = (state.crank_revs, state.crank_time)
        if prev_crank and cur_crank != prev_crank:
            d_rev = (cur_crank[0] - prev_crank[0]) & 0xFFFF
            d_time = (cur_crank[1] - prev_crank[1]) & 0xFFFF
            rpm = d_rev * 1024 * 60 / d_time if d_time else 0
            cadence = int(rpm) if rpm < 250 else 0
        elif prev_crank == cur_crank:
            cadence = 0
        prev_crank = cur_crank

        recording = ride is not None and ride.running
        bits = []
        if state.power:
            bits.append(f"{state.power} W")
        if cadence:
            bits.append(f"{cadence} rpm")
        if state.speed_kph:
            bits.append(f"{state.speed_kph:.1f} km/h")
        if state.hr:
            bits.append(f"{state.hr} bpm")

        title = "🚲 " + " · ".join(bits)
        lines = [title.strip(), "---"]

        if recording:
            lines.append(
                f"● Recording  {ride.elapsed / 60:.0f} min · {ride.avg_power:.0f}W avg"
                f" · {ride.distance / 1000:.1f} km | color=red"
            )
        if state.target_power:
            lines.append(f"Holding {state.target_power:.0f}W")

        if state.sensors:
            for name, gives in state.sensors.items():
                erg = " · holds a target" if state.trainer_controllable else ""
                lines.append(f"{name}: {', '.join(gives)}{erg}")
        else:
            lines.append("Searching for sensors…")
            lines.append("Turn the trainer on and pedal | color=gray")

        try:
            with open(STATUS_FILE, "w") as fh:
                fh.write("\n".join(lines) + "\n")
            with open(STATUS_JSON, "w") as fh:
                json.dump(
                    {
                        "power": state.power,
                        "cadence": cadence,
                        "hr": state.hr,
                        "speed": round(state.speed_kph, 1),
                        "target_power": state.target_power,
                        "recording": recording,
                        "elapsed": round(ride.elapsed) if recording else 0,
                        "avg_power": round(ride.avg_power) if recording else 0,
                        "distance": round(ride.distance) if recording else 0,
                        "sensors": list(state.sensors),
                        "nearby": [
                            {
                                "name": d["name"],
                                "gives": d["gives"],
                                "state": (
                                    "connected"
                                    if d["name"] in state.sensors
                                    else "ignored"
                                    if d["address"] in state.ignored
                                    else "found"
                                ),
                            }
                            for d in state.nearby_now()
                        ],
                        "erg": state.trainer_controllable,
                        "workout": live["plan"].status() if live.get("plan") else None,
                    },
                    fh,
                )
        except OSError:
            pass
        await asyncio.sleep(1)


async def fake_rider(state, rpm=90.0, wheel_circumference_m=2.096, speed_kph=30.0):
    """Pedal a pretend bike, for working on the overlay with no sensor around."""
    tick = 0.25
    crank_frac = wheel_frac = 0.0
    while True:
        crank_frac += rpm / 60.0 * tick
        wheel_frac += (speed_kph / 3.6 / wheel_circumference_m) * tick
        now = int(time.monotonic() * 1024) & 0xFFFF
        if crank_frac >= 1:
            state.crank_revs = (state.crank_revs + int(crank_frac)) & 0xFFFF
            state.crank_time = now
            crank_frac -= int(crank_frac)
        if wheel_frac >= 1:
            state.wheel_revs = (state.wheel_revs + int(wheel_frac)) & 0xFFFF
            state.wheel_time = now
            wheel_frac -= int(wheel_frac)
        state.power = 180
        # A rider with no pulse and no speed cannot exercise the heart rate or
        # speed paths, which is most of what the overlay shows.
        state.hr = 142
        state.speed_kph = speed_kph
        state.touch()
        await asyncio.sleep(tick)


async def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--fake", action="store_true", help="simulate a rider instead of using BLE")
    ap.add_argument("--name", default=None, help="sensor name hint, e.g. Madone")
    ap.add_argument("--ant-relay-lan", action="store_true",
                    help="accept ANT+ relay packets from the network, not just this machine")
    args = ap.parse_args()

    def log(*parts):
        print(time.strftime("%H:%M:%S"), *parts, flush=True)

    state = bike_ble.BikeState()
    if args.fake:
        asyncio.create_task(fake_rider(state))
        log("using a simulated rider (90rpm, 30kph, 180W)")
    else:
        log("scanning for sensors - spin the cranks to wake them")
        asyncio.create_task(bike_ble.run(state, name_hint=args.name, on_status=log))

    # No Mac can hear ANT+ itself, so take it from whatever can. Costs nothing
    # when no relay is running.
    await ant_relay.listen(state, lan=args.ant_relay_lan, log=log)

    live = {"plan": None}
    ride = workout.Ride(state)
    asyncio.create_task(status_loop(state, live, ride))
    try:
        await control_server(state, ride, log, live)
    except OSError as exc:
        # Usually a second copy already running. launchd will retry; say why
        # rather than dumping a traceback into the log every ten seconds.
        log(f"cannot listen on port {CONTROL_PORT}: {exc.strerror}")


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        pass
