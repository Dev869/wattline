"""Self-check: a relayed ANT+ packet becomes a number on the screen.

    python test_relay.py

Sends real datagrams at a real socket, so it covers the whole path an aerial's
packets take - wire format, decode, sensor list - without needing an aerial.
"""

import asyncio
import socket
import struct
import sys

import ant
import ant_relay
import bike_ble

results = []


def check(what, got, want):
    ok = got == want
    results.append(ok)
    print(("ok:   " if ok else "FAIL: ") + what + ("" if ok else f"\n  got {got!r}, want {want!r}"))


async def main():
    ant_relay.RELAY_PORT = 51999
    state = bike_ble.BikeState()
    quiet = []
    await ant_relay.listen(state, log=quiet.append)

    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    target = ("127.0.0.1", ant_relay.RELAY_PORT)

    def send(device_type, payload):
        sock.sendto(bytes([device_type]) + payload, target)

    send(ant.ANT_HR, bytes([0x04, 0xFF, 0xFF, 0xFF]) + struct.pack("<HBB", 100, 5, 143))
    send(ant.ANT_POWER, struct.pack("<BBBBHH", 0x10, 1, 0xFF, 90, 1000, 247))
    await asyncio.sleep(0.2)

    check("heart rate arrived over the wire", state.hr, 143)
    check("power arrived over the wire", state.power, 247)
    check("relayed sensors show up in the list",
          sorted(state.sensors), ["ANT+ heart rate", "ANT+ power"])

    # Junk from the network must not take anything down with it.
    sock.sendto(b"hello", target)
    sock.sendto(bytes([200]) + b"\x00" * 8, target)
    sock.sendto(b"", target)
    await asyncio.sleep(0.2)
    check("junk is dropped, not fatal", state.power, 247)

    send(ant.ANT_POWER, struct.pack("<BBBBHH", 0x10, 2, 0xFF, 91, 1100, 260))
    await asyncio.sleep(0.2)
    check("still listening after the junk", state.power, 260)

    # A relay that goes quiet stops being a sensor - on its own, with nothing
    # arriving to prompt the check, which is the whole point.
    ant_relay.RELAY_TTL = 0.5
    await asyncio.sleep(2.0)
    check("a silent relay drops off the list with no further packets",
          state.sensors, {})

    sock.close()
    print("\nall good" if all(results) else "\nFAILED")
    return 0 if all(results) else 1


sys.exit(asyncio.run(main()))
