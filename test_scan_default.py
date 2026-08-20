"""Self-check: the daemon starts scanning for sensors the moment it is up.

    python test_scan_default.py

The bug this guards: the BLE scan used to wait for something else to ask for
it, so the overlay could sit at zero showing "no sensor connected" while
nothing was ever looking. Stubs out the real Bluetooth scan and checks that
starting the daemon is enough to start looking.
"""

import asyncio
import sys

import bike_ble

started = asyncio.Event()


async def fake_scan(state, name_hint=None, on_status=print):
    started.set()
    await asyncio.sleep(3600)


async def main():
    bike_ble.run = fake_scan

    import daemon

    # A spare control port, so this runs alongside the real daemon.
    daemon.CONTROL_PORT = 51997
    sys.argv = ["daemon.py"]

    task = asyncio.create_task(daemon.main())
    try:
        await asyncio.wait_for(started.wait(), 5)
    except asyncio.TimeoutError:
        print("FAIL: the daemon came up without starting a Bluetooth scan")
        return 1
    finally:
        task.cancel()

    print("ok: scans as soon as it starts")
    return 0


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
