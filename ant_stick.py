"""Emulate an ANT+ USB stick over TCP, fed by real Bluetooth sensor data.

GT Bike V (inside CrossOver) thinks it is talking to a Garmin ANT stick via
DSI_SiUSBXp_3_1.DLL. That DLL is our shim, which forwards the serial byte
stream here. We speak the host side of the ANT message protocol and broadcast
ANT+ profile pages built from whatever bike_ble.py is reading over Bluetooth.

    python ant_stick.py            # bridge, needs a real sensor
    python ant_stick.py --fake     # bridge with a simulated 90rpm rider

Message framing: A4 <len> <msgid> <payload..> <xor checksum incl. sync>
"""

import argparse
import asyncio
import json
import os
import struct
import time

import bike_ble
import plan
import strava
import workout

SYNC = 0xA4
PORT = 51234

# Host -> stick
MSG_UNASSIGN_CHANNEL = 0x41
MSG_ASSIGN_CHANNEL = 0x42
MSG_CHANNEL_PERIOD = 0x43
MSG_SEARCH_TIMEOUT = 0x44
MSG_CHANNEL_RF_FREQ = 0x45
MSG_NETWORK_KEY = 0x46
MSG_RESET_SYSTEM = 0x4A
MSG_OPEN_CHANNEL = 0x4B
MSG_CLOSE_CHANNEL = 0x4C
MSG_REQUEST = 0x4D
MSG_ACK_DATA = 0x4F
MSG_BURST_DATA = 0x50
MSG_CHANNEL_ID = 0x51

# Stick -> host
MSG_BROADCAST_DATA = 0x4E
MSG_CHANNEL_RESPONSE = 0x40
MSG_CAPABILITIES = 0x54
MSG_VERSION = 0x3E
MSG_SERIAL_NUMBER = 0x61
MSG_STARTUP = 0x6F

RESPONSE_NO_ERROR = 0x00
EVENT_TRANSFER_TX_COMPLETED = 0x05

# ANT+ device types we can pretend to be
DEV_POWER = 11
DEV_FEC = 17
DEV_HR = 120
DEV_CSC = 121  # combined speed and cadence
DEV_CADENCE = 122
DEV_SPEED = 123

# Device numbers we advertise, so GT Bike V can pin them in its config
DEVICE_NUMBERS = {
    DEV_CSC: 1121,
    DEV_SPEED: 1123,
    DEV_CADENCE: 1122,
    DEV_POWER: 1111,
    DEV_HR: 1120,
    DEV_FEC: 1117,
}

# FE-C control pages the game sends down to the trainer
PAGE_BASIC_RESISTANCE = 0x30
PAGE_TARGET_POWER = 0x31
PAGE_TRACK_RESISTANCE = 0x33
PAGE_GENERAL_FE = 0x10
PAGE_TRAINER_DATA = 0x19

FE_TRAINER = 25  # equipment type
FE_STATE_IN_USE = 3

WHEEL_CIRCUMFERENCE_M = 2.096  # 700x25c, only used when there is no trainer speed

CAPABILITIES = bytes([8, 3, 0x00, 0xBA, 0x36, 0x00, 0xE7, 0x00])
VERSION = b"AP2USB1.06\x00"
SERIAL_NUMBER = struct.pack("<I", 0x00B14E01)


def frame(msg_id, payload):
    body = bytes([SYNC, len(payload), msg_id]) + bytes(payload)
    checksum = 0
    for b in body:
        checksum ^= b
    return body + bytes([checksum])


class Channel:
    def __init__(self, number):
        self.number = number
        self.assigned = False
        self.open = False
        self.dev_type = 0
        self.dev_number = 0
        self.trans_type = 0
        self.period = 8192  # 1/32768 s units
        self.event_count = 0
        self.accumulated_power = 0
        self.hr_beats = 0
        self.next_tx = 0.0

    @property
    def interval(self):
        return self.period / 32768.0


class AntStick:
    """One connected client (one game session)."""

    def __init__(self, state, writer, log=print):
        self.state = state
        self.writer = writer
        self.log = log
        self.channels = {i: Channel(i) for i in range(8)}
        self.buf = bytearray()
        self._ride_t = None
        self._speed = 0.0
        self._distance = 0.0
        self._wheel_prev = None

    def send(self, msg_id, payload):
        self.writer.write(frame(msg_id, payload))

    def respond(self, channel, msg_id, code=RESPONSE_NO_ERROR):
        self.send(MSG_CHANNEL_RESPONSE, [channel, msg_id, code])

    def feed(self, data):
        """Parse whatever bytes arrived; handle every complete message."""
        self.buf.extend(data)
        while True:
            start = self.buf.find(SYNC)
            if start < 0:
                self.buf.clear()
                return
            del self.buf[:start]
            if len(self.buf) < 4:
                return
            length = self.buf[1]
            total = length + 4
            if len(self.buf) < total:
                return
            msg = bytes(self.buf[:total])
            del self.buf[:total]
            check = 0
            for b in msg[:-1]:
                check ^= b
            if check != msg[-1]:
                self.log(f"bad checksum on msg {msg[2]:#04x}, ignoring")
                continue
            self.handle(msg[2], msg[3:-1])

    def handle(self, msg_id, payload):
        chan_num = payload[0] if payload else 0
        chan = self.channels.get(chan_num & 0x07)

        if msg_id == MSG_RESET_SYSTEM:
            self.log("reset")
            for c in self.channels.values():
                c.assigned = c.open = False
            self.send(MSG_STARTUP, [0x20])
            return

        if msg_id == MSG_REQUEST:
            self.handle_request(chan_num, payload[1])
            return

        if msg_id == MSG_ASSIGN_CHANNEL:
            chan.assigned = True
            chan.open = False
            self.log(f"ch{chan.number}: assigned type={payload[1]:#04x} net={payload[2]}")

        elif msg_id == MSG_CHANNEL_ID:
            chan.dev_number = struct.unpack_from("<H", payload, 1)[0]
            chan.dev_type = payload[3] & 0x7F
            chan.trans_type = payload[4]
            self.log(
                f"ch{chan.number}: searching dev#{chan.dev_number} type={chan.dev_type}"
                f" ({self.profile_name(chan.dev_type)})"
            )

        elif msg_id == MSG_CHANNEL_PERIOD:
            chan.period = struct.unpack_from("<H", payload, 1)[0]

        elif msg_id == MSG_OPEN_CHANNEL:
            chan.open = True
            chan.next_tx = time.monotonic()
            self.log(f"ch{chan.number}: open ({self.profile_name(chan.dev_type)})")

        elif msg_id == MSG_CLOSE_CHANNEL:
            chan.open = False
            self.respond(chan_num, msg_id)
            self.respond(chan_num, 0x01, 0x07)  # EVENT_CHANNEL_CLOSED
            return

        elif msg_id == MSG_UNASSIGN_CHANNEL:
            chan.assigned = chan.open = False

        elif msg_id in (MSG_ACK_DATA, MSG_BURST_DATA):
            self.handle_control_page(payload[1:9])
            self.respond(chan_num, 0x01, EVENT_TRANSFER_TX_COMPLETED)
            return

        # Everything else (network key, RF freq, power, timeouts, lib config)
        # just needs an acknowledgement.
        self.respond(chan_num, msg_id)

    def handle_control_page(self, page):
        """Terrain and workout commands coming back down from the game.

        This is the half that makes hills hurt: GT Bike V sends the slope of
        whatever road you are on, and it ends up as resistance on the trainer.
        """
        if len(page) < 8:
            return
        kind = page[0]

        if kind == PAGE_TRACK_RESISTANCE:
            raw_grade = struct.unpack_from("<H", page, 5)[0]
            if raw_grade != 0xFFFF:  # 0xFFFF means "invalid, ignore"
                grade = raw_grade * 0.01 - 200.0
                self.state.target_grade = grade
                self.state.target_power = None
                if abs(grade - getattr(self, "_last_logged_grade", 999)) >= 0.5:
                    self._last_logged_grade = grade
                    self.log(f"terrain: {grade:+.1f}% -> trainer")
            if page[7] != 0xFF:
                self.state.target_crr = page[7] * 0.00005

        elif kind == PAGE_TARGET_POWER:
            watts = struct.unpack_from("<H", page, 6)[0] * 0.25
            self.state.target_power = watts
            self.log(f"workout: hold {watts:.0f}W -> trainer")

        elif kind == PAGE_BASIC_RESISTANCE:
            # Percentage of the trainer's maximum, in 0.5% steps. No direct
            # FTMS equivalent worth mapping, so treat it as flat road.
            self.state.target_grade = 0.0
            self.state.target_power = None

    def handle_request(self, chan_num, requested):
        if requested == MSG_CAPABILITIES:
            self.send(MSG_CAPABILITIES, CAPABILITIES)
        elif requested == MSG_VERSION:
            self.send(MSG_VERSION, VERSION)
        elif requested == MSG_SERIAL_NUMBER:
            self.send(MSG_SERIAL_NUMBER, SERIAL_NUMBER)
        elif requested == MSG_CHANNEL_ID:
            chan = self.channels[chan_num & 0x07]
            dev = chan.dev_number or DEVICE_NUMBERS.get(chan.dev_type, 1)
            self.send(
                MSG_CHANNEL_ID,
                struct.pack("<BHBB", chan.number, dev, chan.dev_type, chan.trans_type or 1),
            )
        else:
            self.log(f"unhandled request for {requested:#04x}")
            self.respond(chan_num, requested, 0x28)  # INVALID_MESSAGE

    @staticmethod
    def profile_name(dev_type):
        return {
            DEV_POWER: "power",
            DEV_FEC: "smart trainer",
            DEV_HR: "heart rate",
            DEV_CSC: "speed+cadence",
            DEV_CADENCE: "cadence",
            DEV_SPEED: "speed",
        }.get(dev_type, f"type {dev_type}")

    def page_for(self, chan):
        s = self.state
        t = chan.dev_type

        if t == DEV_CSC:
            return struct.pack(
                "<HHHH",
                s.crank_time & 0xFFFF,
                s.crank_revs & 0xFFFF,
                s.wheel_time & 0xFFFF,
                s.wheel_revs & 0xFFFF,
            )
        if t == DEV_SPEED:
            return bytes([0, 0xFF, 0xFF, 0xFF]) + struct.pack(
                "<HH", s.wheel_time & 0xFFFF, s.wheel_revs & 0xFFFF
            )
        if t == DEV_CADENCE:
            return bytes([0, 0xFF, 0xFF, 0xFF]) + struct.pack(
                "<HH", s.crank_time & 0xFFFF, s.crank_revs & 0xFFFF
            )
        if t == DEV_POWER:
            chan.accumulated_power = (chan.accumulated_power + s.power) & 0xFFFF
            cadence = self.cadence_rpm()
            return struct.pack(
                "<BBBBHH",
                0x10,
                chan.event_count & 0xFF,
                0xFF,
                min(254, int(cadence)) if cadence else 0xFF,
                chan.accumulated_power,
                min(65534, s.power),
            )
        if t == DEV_FEC:
            # Trainers alternate a general page with a trainer-specific one.
            speed, distance = self.ride_metrics()
            # broadcast_loop counts the sends, so parity alternates the pages
            if chan.event_count % 2:
                elapsed = int(time.monotonic() * 4) & 0xFF
                return struct.pack(
                    "<BBBBHBB",
                    PAGE_GENERAL_FE,
                    FE_TRAINER,
                    elapsed,
                    int(distance) & 0xFF,
                    min(65534, int(speed / 3.6 * 1000)),
                    s.hr or 0xFF,
                    (FE_STATE_IN_USE << 4) | 0x04,  # in use, distance is real
                )
            chan.accumulated_power = (chan.accumulated_power + s.power) & 0xFFFF
            power = min(4094, int(s.power))
            cadence = int(self.cadence_rpm())
            return struct.pack(
                "<BBBHBBB",
                PAGE_TRAINER_DATA,
                chan.event_count & 0xFF,
                min(254, cadence) if cadence else 0xFF,
                chan.accumulated_power,
                power & 0xFF,
                (power >> 8) & 0x0F,  # high nibble = trainer status, all clear
                FE_STATE_IN_USE << 4,
            )

        if t == DEV_HR:
            if not s.hr:
                return None
            chan.hr_beats = (chan.hr_beats + 1) & 0xFF
            beat_time = int(time.monotonic() * 1024) & 0xFFFF
            return bytes([0, 0xFF, 0xFF, 0xFF]) + struct.pack(
                "<HBB", beat_time, chan.hr_beats, min(255, s.hr)
            )
        return None

    def ride_metrics(self):
        """Speed in kph and distance in metres, for the trainer pages.

        A smart trainer reports its own speed; a wheel sensor gives revolutions
        instead, so derive it. Distance is integrated from speed either way.
        """
        s = self.state
        now = time.monotonic()
        last_t = self._ride_t
        self._ride_t = now

        if s.speed_kph:
            self._speed = s.speed_kph
        else:
            prev, cur = self._wheel_prev, (s.wheel_revs, s.wheel_time)
            self._wheel_prev = cur
            if prev and cur != prev:
                d_rev = (cur[0] - prev[0]) & 0xFFFF
                d_time = (cur[1] - prev[1]) & 0xFFFF
                self._speed = d_rev * WHEEL_CIRCUMFERENCE_M * 1024 / d_time * 3.6 if d_time else 0.0
            elif prev == cur:
                self._speed = 0.0  # not turning: coasting or stopped

        if last_t:
            self._distance += self._speed / 3.6 * (now - last_t)
        return self._speed, self._distance

    def cadence_rpm(self):
        """Crank revs/time deltas -> rpm, for the power page's cadence field."""
        s = self.state
        prev = getattr(self, "_cad_prev", None)
        self._cad_prev = (s.crank_revs, s.crank_time)
        if not prev or prev == self._cad_prev:
            return getattr(self, "_cad_last", 0)
        d_rev = (s.crank_revs - prev[0]) & 0xFFFF
        d_time = (s.crank_time - prev[1]) & 0xFFFF
        rpm = (d_rev * 1024 * 60 / d_time) if d_time else 0
        self._cad_last = rpm if rpm < 250 else 0
        return self._cad_last

    async def broadcast_loop(self):
        """Push a data page on every open channel at its own channel period."""
        while True:
            now = time.monotonic()
            sleep = 0.05
            for chan in self.channels.values():
                if not chan.open:
                    continue
                if now >= chan.next_tx:
                    page = self.page_for(chan)
                    if page is not None:
                        self.send(MSG_BROADCAST_DATA, bytes([chan.number]) + page)
                        chan.event_count += 1
                    chan.next_tx = now + chan.interval
                sleep = min(sleep, max(0.005, chan.next_tx - now))
            await self.writer.drain()
            await asyncio.sleep(sleep)


class BleSupervisor:
    """Scan for sensors only while the game is actually connected.

    The bridge runs from login to shutdown, and a permanent BLE scan is a
    pointless drain on a laptop. Nothing happens until GTA V opens the socket.
    The grace period stops us thrashing: the shim opens and drops a throwaway
    connection every time it probes for a stick.
    """

    def __init__(self, state, name_hint=None, grace=90.0, log=print):
        self.state, self.name_hint, self.grace, self.log = state, name_hint, grace, log
        self.users = 0
        self.task = None
        self.stopper = None

    def acquire(self):
        self.users += 1
        if self.stopper:
            self.stopper.cancel()
            self.stopper = None
        if not self.task:
            self.log("starting Bluetooth scan - spin the cranks to wake the sensor")
            self.task = asyncio.create_task(
                bike_ble.run(self.state, name_hint=self.name_hint, on_status=self.log)
            )

    def release(self):
        self.users = max(0, self.users - 1)
        if self.users == 0 and self.task and not self.stopper:
            self.stopper = asyncio.create_task(self._stop_later())

    async def _stop_later(self):
        await asyncio.sleep(self.grace)
        if self.users == 0 and self.task:
            self.task.cancel()
            self.task = None
            self.log("no game connected, Bluetooth scan stopped")
        self.stopper = None


STATUS_FILE = os.path.expanduser("~/Library/Logs/wattline-status.txt")
STATUS_JSON = os.path.expanduser("~/Library/Logs/wattline-status.json")
CONTROL_PORT = 51235


async def control_server(state, ble, ride, log, live):
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
            state.target_grade = None
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
            if ble:
                ble.acquire()
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
            if ble:
                ble.release()
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
    while True:
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
        riding = live["clients"] > 0 or recording
        bits = []
        if state.power:
            bits.append(f"{state.power} W")
        if cadence:
            bits.append(f"{cadence} rpm")
        if state.speed_kph:
            bits.append(f"{state.speed_kph:.1f} km/h")
        if state.hr:
            bits.append(f"{state.hr} bpm")
        if state.target_grade is not None:
            bits.append(f"{state.target_grade:+.1f}% grade")

        title = "🚲 " + (" · ".join(bits) if riding and bits else ("riding" if riding else ""))
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
                hills = " · hills on" if state.trainer_controllable else ""
                lines.append(f"{name}: {', '.join(gives)}{hills}")
        else:
            lines.append("No sensor connected")
            lines.append("Turn the trainer on and pedal | color=gray")

        lines.append(
            "Game connected" if live["clients"] else "GTA V not running | color=gray"
        )

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
                        "grade": state.target_grade,
                        "target_power": state.target_power,
                        "recording": recording,
                        "elapsed": round(ride.elapsed) if recording else 0,
                        "avg_power": round(ride.avg_power) if recording else 0,
                        "distance": round(ride.distance) if recording else 0,
                        "sensors": list(state.sensors),
                        "hills": state.trainer_controllable,
                        "game": bool(live["clients"]),
                        "workout": live["plan"].status() if live.get("plan") else None,
                    },
                    fh,
                )
        except OSError:
            pass
        await asyncio.sleep(1)


async def serve_client(state, reader, writer, ble=None, log=print, live=None):
    peer = writer.get_extra_info("peername")
    log(f"game connected from {peer}")
    if live is not None:
        live["clients"] += 1
    if ble:
        ble.acquire()
    stick = AntStick(state, writer, log)
    tx = asyncio.create_task(stick.broadcast_loop())
    try:
        while True:
            data = await reader.read(4096)
            if not data:
                break
            stick.feed(data)
            await writer.drain()
    except (ConnectionResetError, BrokenPipeError):
        pass
    finally:
        tx.cancel()
        writer.close()
        if live is not None:
            live["clients"] = max(0, live["clients"] - 1)
        if ble:
            ble.release()
        log("game disconnected")


async def fake_rider(state, rpm=90.0, wheel_circumference_m=2.096, speed_kph=30.0):
    """Pedal a pretend bike, for testing the bridge with no sensor around."""
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
    ap.add_argument("--port", type=int, default=PORT)
    ap.add_argument("--fake", action="store_true", help="simulate a rider instead of using BLE")
    ap.add_argument("--name", default=None, help="sensor name hint, e.g. Madone")
    ap.add_argument("--always", action="store_true", help="keep scanning even with no game connected")
    args = ap.parse_args()

    def log(*parts):
        print(time.strftime("%H:%M:%S"), *parts, flush=True)

    state = bike_ble.BikeState()
    ble = None
    if args.fake:
        asyncio.create_task(fake_rider(state))
        log("using a simulated rider (90rpm, 30kph, 180W)")
    else:
        ble = BleSupervisor(state, name_hint=args.name, log=log)
        if args.always:
            ble.acquire()
            ble = None  # scanning permanently, nothing left to manage

    live = {"clients": 0, "plan": None}
    ride = workout.Ride(state)
    asyncio.create_task(status_loop(state, live, ride))
    asyncio.create_task(control_server(state, ble, ride, log, live))
    try:
        server = await asyncio.start_server(
            lambda r, w: serve_client(state, r, w, ble=ble, log=log, live=live),
            "127.0.0.1",
            args.port,
        )
    except OSError as exc:
        # Usually a second copy already running. launchd will retry; say why
        # rather than dumping a traceback into the log every ten seconds.
        log(f"cannot listen on port {args.port}: {exc.strerror}")
        return
    log(f"listening on 127.0.0.1:{args.port} - waiting for GTA V")
    async with server:
        await server.serve_forever()


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        pass
