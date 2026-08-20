"""Decode ANT+ broadcast pages into the same BikeState the BLE side fills.

ANT+ sensors send an 8-byte payload four times a second, and the meaning of
those eight bytes depends on the device type of the channel they arrived on.
That decoding is pure arithmetic - no radio, no licence, no hardware - so it
lives here on its own, and whatever manages to get the bytes off the air feeds
them in. Today that is ant_relay (some other machine's radio, over the
network); a dongle, an nRF52 or an SDR would all land in the same place.

    apply(state, ANT_POWER, payload)   # -> state.power, cadence, ...

See docs/ant-without-a-stick.md for why getting the bytes is the hard part.
"""

import struct
import time

# ANT+ device profile numbers, as they appear in a channel ID.
ANT_POWER = 11
ANT_FEC = 17  # fitness equipment control, i.e. a smart trainer
ANT_HR = 120
ANT_CSC = 121  # combined speed and cadence
ANT_CADENCE = 122
ANT_SPEED = 123

DEVICE_NAMES = {
    ANT_POWER: "power",
    ANT_FEC: "smart trainer",
    ANT_HR: "heart rate",
    ANT_CSC: "speed + cadence",
    ANT_CADENCE: "cadence",
    ANT_SPEED: "speed",
}

PAGE_GENERAL_FE = 0x10
PAGE_TRAINER_DATA = 0x19
PAGE_POWER_ONLY = 0x10

INVALID_BYTE = 0xFF
WHEEL_CIRCUMFERENCE_M = 2.096  # 700x25c, for sensors that only count revolutions


class AntError(ValueError):
    """A payload that is not eight bytes, or a device type we do not decode."""


def apply(state, device_type, payload):
    """Fold one broadcast page into `state`. Returns what it managed to read.

    Unknown pages are not an error: every profile defines pages we do not care
    about (manufacturer ID, battery, calibration) and a sensor interleaves them
    with the data ones. Returning an empty tuple for those keeps the caller
    simple - it never has to know which page numbers matter.
    """
    if len(payload) != 8:
        raise AntError(f"an ANT+ page is 8 bytes, got {len(payload)}")
    decoder = _DECODERS.get(device_type)
    if decoder is None:
        raise AntError(f"no decoder for ANT+ device type {device_type}")
    return decoder(state, payload)


def _heart_rate(state, page):
    """Every HR page shares its last four bytes, so the page number is noise.

    Bit 7 of byte 0 is a toggle the transmitter flips to advertise that it can
    send more than the legacy page, which is why the page number is masked off
    rather than compared.
    """
    hr = page[7]
    if not hr:
        return ()
    state.hr = hr
    state.touch()
    return ("hr",)


def _speed_and_cadence(state, page):
    crank_time, crank_revs, wheel_time, wheel_revs = struct.unpack("<HHHH", page)
    state.crank_time, state.crank_revs = crank_time, crank_revs
    state.wheel_time, state.wheel_revs = wheel_time, wheel_revs
    state.touch()
    return ("cadence", "speed")


def _speed(state, page):
    wheel_time, wheel_revs = struct.unpack("<HH", page[4:])
    state.wheel_time, state.wheel_revs = wheel_time, wheel_revs
    state.touch()
    return ("speed",)


def _cadence(state, page):
    crank_time, crank_revs = struct.unpack("<HH", page[4:])
    state.crank_time, state.crank_revs = crank_time, crank_revs
    state.touch()
    return ("cadence",)


def _power(state, page):
    if page[0] != PAGE_POWER_ONLY:
        return ()  # torque, calibration, manufacturer info - not our business
    cadence = page[3]
    state.power = struct.unpack("<H", page[6:8])[0]
    read = ["power"]
    if cadence != INVALID_BYTE:
        _synth_crank(state, cadence)
        read.append("cadence")
    state.touch()
    return tuple(read)


def _trainer(state, page):
    """A trainer alternates a general page with a trainer-specific one."""
    if page[0] == PAGE_GENERAL_FE:
        read = []
        speed_mm_s = struct.unpack("<H", page[4:6])[0]
        if speed_mm_s != 0xFFFF:
            state.speed_kph = speed_mm_s / 1000.0 * 3.6
            read.append("speed")
        if page[6] != INVALID_BYTE:
            state.hr = page[6]
            read.append("hr")
        if read:
            state.touch()
        return tuple(read)

    if page[0] == PAGE_TRAINER_DATA:
        # Instantaneous power is twelve bits: a whole low byte, then the low
        # nibble of the next. The high nibble of that byte is trainer status.
        power = page[5] | ((page[6] & 0x0F) << 8)
        read = []
        if power != 0xFFF:
            state.power = power
            read.append("power")
        if page[2] != INVALID_BYTE:
            _synth_crank(state, page[2])
            read.append("cadence")
        if read:
            state.touch()
        return tuple(read)

    return ()


def _synth_crank(state, rpm):
    """Turn an rpm reading into the revolution counter the rest of the app uses.

    Power meters and trainers report cadence as a number, where a cadence
    sensor reports revolutions and the time of the last one. Integrating rpm
    back into that pair means everything downstream sees one shape, whichever
    kind of sensor is on the bike. Same trick as the BLE side, kept separate
    because the two can be connected at once and must not share a remainder.
    """
    now = time.monotonic()
    last = getattr(state, "_ant_crank_t", None)
    state._ant_crank_t = now
    if last is None or rpm <= 0:
        return
    frac = getattr(state, "_ant_crank_frac", 0.0) + rpm / 60.0 * (now - last)
    whole = int(frac)
    state._ant_crank_frac = frac - whole
    if whole:
        state.crank_revs = (state.crank_revs + whole) & 0xFFFF
        state.crank_time = int(now * 1024) & 0xFFFF


_DECODERS = {
    ANT_HR: _heart_rate,
    ANT_CSC: _speed_and_cadence,
    ANT_SPEED: _speed,
    ANT_CADENCE: _cadence,
    ANT_POWER: _power,
    ANT_FEC: _trainer,
}
