"""Self-check: ANT+ pages decode back to the numbers they were built from.

    python test_ant.py

Every case here builds a real page the way a sensor would, hands it to the
decoder, and checks what comes out - so the byte layouts are pinned from both
ends rather than trusted once. That matters more than usual: there is no ANT+
radio on this machine to check against, so this is the only thing standing
between a layout mistake and a wrong number on the overlay.
"""

import struct
import sys
import time

import ant


class FakeState:
    """The parts of BikeState the decoders touch."""

    def __init__(self):
        self.power = self.hr = 0
        self.speed_kph = 0.0
        self.crank_revs = self.crank_time = 0
        self.wheel_revs = self.wheel_time = 0
        self.updated = 0.0

    def touch(self):
        self.updated = time.monotonic()


results = []


def check(what, got, want):
    ok = got == want
    results.append(ok)
    print(("ok:   " if ok else "FAIL: ") + what + ("" if ok else f"\n  got {got!r}, want {want!r}"))


def close(what, got, want, tolerance=0.05):
    check(what, abs(got - want) < tolerance, True)


def heart_rate():
    state = FakeState()
    # Page 4, toggle bit set: previous beat time, beat count, computed HR.
    page = bytes([0x84, 0xFF, 0xFF, 0xFF]) + struct.pack("<HBB", 12345, 200, 148)
    check("heart rate is read whatever the page number", ant.apply(state, ant.ANT_HR, page), ("hr",))
    check("heart rate value", state.hr, 148)

    # A strap that has not found a pulse yet sends zero, which is not a reading.
    quiet = bytes([0x04, 0xFF, 0xFF, 0xFF]) + struct.pack("<HBB", 0, 0, 0)
    state.hr = 148
    check("a zero pulse is not a reading", ant.apply(state, ant.ANT_HR, quiet), ())
    check("...and does not wipe the last one", state.hr, 148)


def speed_and_cadence():
    state = FakeState()
    page = struct.pack("<HHHH", 1024, 500, 2048, 9000)
    check("combined sensor reports both", ant.apply(state, ant.ANT_CSC, page), ("cadence", "speed"))
    check("crank revolutions", (state.crank_time, state.crank_revs), (1024, 500))
    check("wheel revolutions", (state.wheel_time, state.wheel_revs), (2048, 9000))

    state = FakeState()
    speed_only = bytes([0, 0xFF, 0xFF, 0xFF]) + struct.pack("<HH", 4096, 77)
    check("speed-only sensor", ant.apply(state, ant.ANT_SPEED, speed_only), ("speed",))
    check("...leaves the cranks alone", (state.crank_time, state.crank_revs), (0, 0))
    check("...and reads the wheel", (state.wheel_time, state.wheel_revs), (4096, 77))

    state = FakeState()
    cadence_only = bytes([0, 0xFF, 0xFF, 0xFF]) + struct.pack("<HH", 8192, 42)
    check("cadence-only sensor", ant.apply(state, ant.ANT_CADENCE, cadence_only), ("cadence",))
    check("...reads the cranks", (state.crank_time, state.crank_revs), (8192, 42))


def power_meter():
    state = FakeState()
    page = struct.pack("<BBBBHH", 0x10, 7, 0xFF, 88, 40000, 231)
    check("power page", ant.apply(state, ant.ANT_POWER, page), ("power", "cadence"))
    check("watts", state.power, 231)

    # A crank-based meter with no cadence sends 0xFF for it.
    state = FakeState()
    no_cadence = struct.pack("<BBBBHH", 0x10, 8, 0xFF, 0xFF, 40231, 194)
    check("power without cadence", ant.apply(state, ant.ANT_POWER, no_cadence), ("power",))
    check("...still gives watts", state.power, 194)

    # Torque pages interleave with the data ones and are not ours to read.
    state = FakeState()
    torque = struct.pack("<BBBBHH", 0x12, 9, 10, 90, 1234, 5678)
    check("a torque page is skipped, not an error", ant.apply(state, ant.ANT_POWER, torque), ())
    check("...and changes nothing", state.power, 0)


def trainer():
    state = FakeState()
    # General FE data: type, elapsed, distance, speed in mm/s, heart rate, state.
    general = struct.pack("<BBBBHBB", 0x10, 25, 100, 50, 8333, 151, 0x34)
    check("trainer general page", ant.apply(state, ant.ANT_FEC, general), ("speed", "hr"))
    close("speed in km/h", state.speed_kph, 30.0, tolerance=0.01)
    check("heart rate through the trainer", state.hr, 151)

    # Specific trainer data. Power is twelve bits split across two bytes, so
    # anything over 255 W is the case that catches a botched layout.
    state = FakeState()
    watts = 823
    specific = struct.pack("<BBBHBBB", 0x19, 3, 95, 41000,
                           watts & 0xFF, ((watts >> 8) & 0x0F) | 0x30, 0x30)
    check("trainer data page", ant.apply(state, ant.ANT_FEC, specific), ("power", "cadence"))
    check("twelve-bit power survives the split", state.power, watts)

    # 0xFFF means "not sending power", which is not the same as zero watts.
    state = FakeState()
    state.power = 200
    none = struct.pack("<BBBHBBB", 0x19, 4, 0xFF, 41000, 0xFF, 0x0F, 0x30)
    check("an absent power reading is skipped", ant.apply(state, ant.ANT_FEC, none), ())
    check("...and does not become zero watts", state.power, 200)


def rejects_rubbish():
    state = FakeState()
    for bad, why in [(b"\x00" * 7, "seven bytes"), (b"\x00" * 9, "nine bytes"), (b"", "nothing")]:
        try:
            ant.apply(state, ant.ANT_HR, bad)
            check(f"rejects {why}", "accepted", "rejected")
        except ant.AntError:
            check(f"rejects {why}", "rejected", "rejected")
    try:
        ant.apply(state, 200, b"\x00" * 8)
        check("rejects an unknown device type", "accepted", "rejected")
    except ant.AntError:
        check("rejects an unknown device type", "rejected", "rejected")


for case in (heart_rate, speed_and_cadence, power_meter, trainer, rejects_rubbish):
    case()

print("\nall good" if all(results) else "\nFAILED")
sys.exit(0 if all(results) else 1)
