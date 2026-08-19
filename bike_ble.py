"""Read real cycling data from BLE sensors on macOS (CoreBluetooth via bleak).

Normalises CSC / Cycling Power / FTMS / Heart Rate into one BikeState.
Event times are kept in 1/1024 s units, which is what ANT+ wants too, so they
pass straight through to the ANT emulator with no conversion.

Run directly to check your sensor:  python bike_ble.py
"""

import asyncio
import struct
import time

from bleak import BleakClient, BleakScanner

CSC_SVC = "00001816-0000-1000-8000-00805f9b34fb"
CSC_MEAS = "00002a5b-0000-1000-8000-00805f9b34fb"
CP_SVC = "00001818-0000-1000-8000-00805f9b34fb"
CP_MEAS = "00002a63-0000-1000-8000-00805f9b34fb"
FTMS_SVC = "00001826-0000-1000-8000-00805f9b34fb"
FTMS_BIKE = "00002ad2-0000-1000-8000-00805f9b34fb"
FTMS_CONTROL = "00002ad9-0000-1000-8000-00805f9b34fb"
HR_SVC = "0000180d-0000-1000-8000-00805f9b34fb"
HR_MEAS = "00002a37-0000-1000-8000-00805f9b34fb"

WANTED = {CSC_SVC, CP_SVC, FTMS_SVC, HR_SVC}


class BikeState:
    """Latest sensor values. Written by BLE callbacks, read by whoever."""

    def __init__(self):
        self.wheel_revs = 0  # cumulative
        self.wheel_time = 0  # 1/1024 s, wraps at 16 bit
        self.crank_revs = 0
        self.crank_time = 0
        self.power = 0  # watts
        self.hr = 0  # bpm
        self.speed_kph = 0.0  # only when a trainer reports it directly
        self.updated = 0.0  # monotonic time of last update

        # Set by the game, sent down to the trainer. Grade is the one that
        # matters: it turns Los Santos hills into real resistance.
        self.target_grade = None  # percent, e.g. 4.5 for a 4.5% climb
        self.target_crr = 0.004  # rolling resistance coefficient
        self.target_power = None  # watts, when the game runs a workout instead
        self.trainer_controllable = False
        self.sensors = {}  # name -> what it gives us, for the menu bar

    def touch(self):
        self.updated = time.monotonic()

    @property
    def stale(self):
        return self.updated == 0.0 or (time.monotonic() - self.updated) > 5.0

    def __str__(self):
        return (
            f"wheel={self.wheel_revs:>7} @{self.wheel_time:>5}  "
            f"crank={self.crank_revs:>6} @{self.crank_time:>5}  "
            f"pwr={self.power:>4}W  hr={self.hr:>3}  "
            f"spd={self.speed_kph:5.1f}kph  {'STALE' if self.stale else 'live'}"
        )


def _handle_csc(state, data):
    flags = data[0]
    i = 1
    if flags & 0x01:
        state.wheel_revs, state.wheel_time = struct.unpack_from("<IH", data, i)
        i += 6
    if flags & 0x02:
        state.crank_revs, state.crank_time = struct.unpack_from("<HH", data, i)
    state.touch()


def _handle_cp(state, data):
    flags, power = struct.unpack_from("<Hh", data, 0)
    state.power = max(0, power)
    i = 4
    if flags & 0x01:  # pedal power balance
        i += 1
    if flags & 0x04:  # accumulated torque
        i += 2
    if flags & 0x10:  # wheel revolution data (uint32 revs + uint16 time @1/2048s)
        revs, t2048 = struct.unpack_from("<IH", data, i)
        state.wheel_revs, state.wheel_time = revs, (t2048 // 2) & 0xFFFF
        i += 6
    if flags & 0x20:  # crank revolution data
        state.crank_revs, state.crank_time = struct.unpack_from("<HH", data, i)
    state.touch()


def _handle_ftms(state, data):
    flags = struct.unpack_from("<H", data, 0)[0]
    i = 2
    if not flags & 0x01:  # bit clear => instantaneous speed present
        state.speed_kph = struct.unpack_from("<H", data, i)[0] / 100.0
        i += 2
    if flags & 0x02:  # average speed
        i += 2
    if flags & 0x04:  # instantaneous cadence, 0.5 rpm units
        rpm = struct.unpack_from("<H", data, i)[0] / 2.0
        _synth_crank(state, rpm)
        i += 2
    if flags & 0x08:
        i += 2
    if flags & 0x10:  # total distance, uint24
        i += 3
    if flags & 0x20:  # resistance level
        i += 2
    if flags & 0x40:  # instantaneous power
        state.power = max(0, struct.unpack_from("<h", data, i)[0])
    state.touch()


def _synth_crank(state, rpm):
    """Trainers report cadence as rpm, not revolutions. ANT+ wants revolutions,
    so integrate rpm into a rev counter and matching event time."""
    now = time.monotonic()
    last = getattr(state, "_crank_synth_t", None)
    state._crank_synth_t = now
    if last is None or rpm <= 0:
        return
    revs = rpm / 60.0 * (now - last)
    frac = getattr(state, "_crank_frac", 0.0) + revs
    whole = int(frac)
    state._crank_frac = frac - whole
    if whole:
        state.crank_revs = (state.crank_revs + whole) & 0xFFFF
        state.crank_time = int(now * 1024) & 0xFFFF


def _handle_hr(state, data):
    flags = data[0]
    state.hr = struct.unpack_from("<H", data, 1)[0] if flags & 0x01 else data[1]
    state.touch()


HANDLERS = {
    CSC_MEAS: _handle_csc,
    CP_MEAS: _handle_cp,
    FTMS_BIKE: _handle_ftms,
    HR_MEAS: _handle_hr,
}


async def find_sensors(timeout=15.0, name_hint=None):
    """Return devices advertising a cycling service, or matching name_hint.

    Sensors sleep when the bike is still, so they only turn up if you spin the
    cranks or wheel while this runs.
    """
    found = {}
    devices = await BleakScanner.discover(timeout=timeout, return_adv=True)
    for addr, (dev, adv) in devices.items():
        uuids = {u.lower() for u in adv.service_uuids}
        hit = bool(uuids & WANTED)
        if name_hint and dev.name and name_hint.lower() in dev.name.lower():
            hit = True
        if hit:
            found[addr] = dev
    return list(found.values())


async def _subscribe(client, state):
    """Subscribe to every cycling characteristic this device happens to have."""
    subscribed = []
    for svc in client.services:
        for ch in svc.characteristics:
            fn = HANDLERS.get(ch.uuid.lower())
            if fn and "notify" in ch.properties:
                await client.start_notify(ch, lambda _s, d, f=fn: f(state, d))
                subscribed.append(ch.uuid[4:8])
            elif ch.uuid.lower() == FTMS_CONTROL:
                await _take_control(client, ch, state)
                subscribed.append("2ad9 (control)")
    return subscribed


async def _take_control(client, char, state):
    """Claim the trainer's control point so we can set resistance.

    A trainer ignores every command until control is requested, and drops back
    to manual if nothing talks to it, so this has to happen on each connect.
    """
    await client.write_gatt_char(char, bytes([0x00]), response=True)  # request control
    await client.write_gatt_char(char, bytes([0x07]), response=True)  # start/resume
    state.trainer_controllable = True
    asyncio.create_task(_control_loop(client, char, state))


async def _control_loop(client, char, state):
    """Push grade changes down to the trainer as the game sends them.

    Only on change, and no faster than 4Hz: control points are slow, and
    hammering one with identical values makes trainers stutter.
    """
    last = object()
    while client.is_connected:
        target = (state.target_power, state.target_grade, state.target_crr)
        if target != last:
            try:
                if state.target_power is not None:
                    await client.write_gatt_char(
                        char, struct.pack("<Bh", 0x05, int(state.target_power)), response=True
                    )
                elif state.target_grade is not None:
                    await client.write_gatt_char(
                        char,
                        struct.pack(
                            "<BhhBB",
                            0x11,  # set indoor bike simulation parameters
                            0,  # wind speed, 0.001 m/s - the game models its own
                            int(round(state.target_grade * 100)),  # 0.01 %
                            int(round(state.target_crr / 0.0001)),
                            int(round(0.51 / 0.01)),  # wind resistance coefficient
                        ),
                        response=True,
                    )
                last = target
            except Exception:
                # Trainer busy or gone; the next pass retries.
                pass
        await asyncio.sleep(0.25)


async def run(state, name_hint=None, on_status=print):
    """Connect to sensors and keep them connected, feeding `state` forever."""
    # Bikes carry plenty of bluetooth that is not a sensor - Di2, lights, head
    # units. Once something proves it has nothing to offer, stop redialling it.
    useless = set()
    while True:
        devices = [
            d for d in await find_sensors(name_hint=name_hint) if d.address not in useless
        ]
        if not devices:
            on_status("no cycling sensors advertising - spin the cranks and wait")
            continue
        await asyncio.gather(
            *(_hold(d, state, on_status, useless) for d in devices),
            return_exceptions=True,
        )


async def _hold(device, state, on_status, useless=None):
    try:
        async with BleakClient(device) as client:
            subs = await _subscribe(client, state)
            if not subs:
                offered = ", ".join(sorted(s.uuid[4:8] for s in client.services))
                on_status(f"{device.name}: not a cycling sensor (services: {offered})")
                if useless is not None:
                    useless.add(device.address)
                return
            on_status(f"{device.name}: connected, reading {', '.join(subs)}")
            name = device.name or device.address
            state.sensors[name] = subs
            try:
                while client.is_connected:
                    await asyncio.sleep(1.0)
            finally:
                state.sensors.pop(name, None)
    except Exception as exc:  # sensor slept, moved out of range, etc
        on_status(f"{device.name or device.address}: {exc}")
    on_status(f"{device.name or device.address}: disconnected")


async def _main():
    state = BikeState()
    printer = asyncio.create_task(_print_loop(state))
    try:
        await run(state, name_hint="Madone")
    finally:
        printer.cancel()


async def _print_loop(state):
    while True:
        print(f"\r{state}", end="", flush=True)
        await asyncio.sleep(0.5)


if __name__ == "__main__":
    try:
        asyncio.run(_main())
    except KeyboardInterrupt:
        print()
