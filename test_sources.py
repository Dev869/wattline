"""Self-check: a number is only taken from the sensor it was picked from.

    python test_sources.py

The bug this guards: a trainer and a power meter both shout power, and a
trainer that also reports cadence drowns out a cadence sensor. Picking a
source in the settings window has to actually stop the other one writing.
No Bluetooth involved - the notification handlers are called directly.
"""

import struct
import sys

import bike_ble

TRAINER, METER = "AA", "BB"

# Cycling Power measurement: flags say "crank data present", then 210 watts,
# then the crank counter.
CP_PACKET = struct.pack("<Hh", 0x20, 210) + struct.pack("<HH", 5, 1024)


def check(what, got, want):
    if got != want:
        print(f"FAIL: {what}\n  got  {got}\n  want {want}")
        return False
    print(f"ok: {what}")
    return True


def feed(state, address):
    bike_ble._handle_cp(state, CP_PACKET, state.allowed(address))


def main():
    ok = True

    # Nothing picked: whatever is on the bike gets read, which is what happens
    # when there is only a trainer.
    state = bike_ble.BikeState()
    feed(state, TRAINER)
    ok &= check("with no picks the trainer is read", (state.power, state.crank_revs), (210, 5))

    # Power from the meter, cadence from the trainer.
    state = bike_ble.BikeState()
    state.sources = {"power": METER, "cadence": TRAINER}
    feed(state, TRAINER)
    ok &= check("the trainer's power is ignored", state.power, 0)
    ok &= check("the trainer's cadence is kept", state.crank_revs, 5)

    state.power, state.crank_revs = 0, 0
    feed(state, METER)
    ok &= check("the meter's power is kept", state.power, 210)
    ok &= check("the meter's cadence is ignored", state.crank_revs, 0)

    # Heart rate is on its own strap; a trainer claiming it is still ignored.
    state = bike_ble.BikeState()
    state.sources = {"hr": "CC"}
    bike_ble._handle_hr(state, bytes([0x00, 150]), state.allowed(TRAINER))
    ok &= check("a strap that was not picked is ignored", state.hr, 0)
    bike_ble._handle_hr(state, bytes([0x00, 150]), state.allowed("CC"))
    ok &= check("the picked strap is read", state.hr, 150)

    print("all good" if ok else "FAILED")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
