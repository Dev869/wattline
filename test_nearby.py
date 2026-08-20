"""Self-check: the scan reports what it hears, in words, while it is hearing it.

    python test_nearby.py

The settings window lists whatever is advertising nearby, so this checks the
three things that list depends on: only cycling kit gets through, each entry
says what it offers rather than a service UUID, and anything that has gone
quiet drops off. Stubs the scanner - no Bluetooth, no trainer, no waiting.
"""

import asyncio
import sys

import bike_ble


class FakeAdvert:
    def __init__(self, uuids):
        self.service_uuids = uuids


class FakeDevice:
    def __init__(self, name, address):
        self.name, self.address = name, address


class FakeScanner:
    """Stands in for BleakScanner: hands the callback a room's worth of adverts."""

    adverts = []

    def __init__(self, detection_callback=None, **kwargs):
        self.callback = detection_callback

    async def __aenter__(self):
        for device, advert in FakeScanner.adverts:
            self.callback(device, advert)
        return self

    async def __aexit__(self, *exc):
        return False


def check(what, got, want):
    if got != want:
        print(f"FAIL: {what}\n  got  {got}\n  want {want}")
        return False
    print(f"ok: {what}")
    return True


async def main():
    bike_ble.BleakScanner = FakeScanner
    trainer = FakeDevice("KICKR CORE 2E2F", "AA")
    strap = FakeDevice("HRM-Dual", "BB")
    lamp = FakeDevice("Flare RT", "CC")
    FakeScanner.adverts = [
        (trainer, FakeAdvert([bike_ble.FTMS_SVC, bike_ble.CP_SVC])),
        (strap, FakeAdvert([bike_ble.HR_SVC])),
        (lamp, FakeAdvert(["0000fd6f-0000-1000-8000-00805f9b34fb"])),
    ]

    state = bike_ble.BikeState()
    found = await bike_ble.find_sensors(timeout=0, nearby=state.nearby)

    ok = check(
        "the bike light is not offered as a sensor",
        sorted(d.address for d in found),
        ["AA", "BB"],
    )
    ok &= check(
        "the trainer is described in words",
        state.nearby["AA"]["gives"],
        ["power", "smart trainer"],
    )
    ok &= check("the strap is a heart rate monitor", state.nearby["BB"]["gives"], ["heart rate"])
    ok &= check("both are listed as nearby", len(state.nearby_now()), 2)

    # A sensor that has gone back to sleep stops being "nearby".
    state.nearby["BB"]["seen"] -= bike_ble.NEARBY_TTL + 1
    ok &= check(
        "a sensor gone quiet drops off",
        [d["name"] for d in state.nearby_now()],
        ["KICKR CORE 2E2F"],
    )

    print("all good" if ok else "FAILED")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
