"""Self-check: pretend to be GT Bike V and confirm the bridge answers correctly.

    python test_bridge.py

Drives the emulator the way the ANT library does - reset, capabilities, assign
a speed+cadence channel, open it - then checks that real page data arrives and
that the pedal counter actually advances.
"""

import asyncio
import struct
import sys

import ant_stick
from ant_stick import frame


class Host:
    """Minimal ANT host: sends commands, collects replies."""

    def __init__(self, reader, writer):
        self.reader, self.writer = reader, writer
        self.buf = bytearray()

    async def send(self, msg_id, payload):
        self.writer.write(frame(msg_id, payload))
        await self.writer.drain()

    async def recv(self, timeout=3.0):
        while True:
            if len(self.buf) >= 4 and self.buf[0] == ant_stick.SYNC:
                total = self.buf[1] + 4
                if len(self.buf) >= total:
                    msg = bytes(self.buf[:total])
                    del self.buf[:total]
                    check = 0
                    for b in msg[:-1]:
                        check ^= b
                    assert check == msg[-1], f"bad checksum from stick: {msg.hex()}"
                    return msg[2], msg[3:-1]
            chunk = await asyncio.wait_for(self.reader.read(4096), timeout)
            assert chunk, "bridge closed the connection"
            self.buf.extend(chunk)

    async def expect(self, msg_id, timeout=3.0):
        for _ in range(50):
            mid, payload = await self.recv(timeout)
            if mid == msg_id:
                return payload
        raise AssertionError(f"never saw message {msg_id:#04x}")


async def main():
    state = ant_stick.bike_ble.BikeState()
    rider = asyncio.create_task(ant_stick.fake_rider(state, rpm=90.0, speed_kph=30.0))
    server = await asyncio.start_server(
        lambda r, w: ant_stick.serve_client(state, r, w, log=lambda *_: None),
        "127.0.0.1",
        0,
    )
    port = server.sockets[0].getsockname()[1]

    reader, writer = await asyncio.open_connection("127.0.0.1", port)
    host = Host(reader, writer)

    await host.send(ant_stick.MSG_RESET_SYSTEM, [0])
    reason = await host.expect(ant_stick.MSG_STARTUP)
    assert reason == b"\x20", f"unexpected startup reason {reason.hex()}"
    print("startup message      ok")

    await host.send(ant_stick.MSG_REQUEST, [0, ant_stick.MSG_CAPABILITIES])
    caps = await host.expect(ant_stick.MSG_CAPABILITIES)
    assert caps[0] >= 4, f"stick claims only {caps[0]} channels"
    print(f"capabilities         ok ({caps[0]} channels, {caps[1]} networks)")

    await host.send(ant_stick.MSG_NETWORK_KEY, [0] + [0xB9, 0xA5, 0x21, 0xFB, 0xBD, 0x72, 0xC3, 0x45])
    mid, payload = await host.recv()
    assert (mid, payload[1], payload[2]) == (ant_stick.MSG_CHANNEL_RESPONSE, ant_stick.MSG_NETWORK_KEY, 0)
    print("network key accepted ok")

    await host.send(ant_stick.MSG_ASSIGN_CHANNEL, [0, 0x00, 0])
    await host.expect(ant_stick.MSG_CHANNEL_RESPONSE)
    await host.send(ant_stick.MSG_CHANNEL_ID, [0, 0, 0, ant_stick.DEV_CSC, 0])
    await host.expect(ant_stick.MSG_CHANNEL_RESPONSE)
    await host.send(ant_stick.MSG_CHANNEL_PERIOD, [0, 0x96, 0x1F])  # 8086 -> 4.05 Hz
    await host.expect(ant_stick.MSG_CHANNEL_RESPONSE)
    await host.send(ant_stick.MSG_OPEN_CHANNEL, [0])
    await host.expect(ant_stick.MSG_CHANNEL_RESPONSE)
    print("channel setup        ok")

    first = await host.expect(ant_stick.MSG_BROADCAST_DATA, timeout=5.0)
    assert first[0] == 0, "broadcast arrived on the wrong channel"
    _, crank0, _, wheel0 = struct.unpack("<HHHH", first[1:])

    # Count pages rather than wall clock: the socket buffers broadcasts, so
    # sleeping would compare against a stale page still sitting in the queue.
    periods = 8  # 8086 counts -> 8 pages is 1.97s of riding
    for _ in range(periods):
        page = await host.expect(ant_stick.MSG_BROADCAST_DATA, timeout=5.0)
    _, crank1, _, wheel1 = struct.unpack("<HHHH", page[1:])

    crank_delta = (crank1 - crank0) & 0xFFFF
    wheel_delta = (wheel1 - wheel0) & 0xFFFF
    # 90rpm for 1.97s is ~3 cranks; 30kph on a 2.096m wheel is ~8 revs
    assert 2 <= crank_delta <= 5, f"implausible crank delta {crank_delta} at 90rpm"
    assert 6 <= wheel_delta <= 11, f"implausible wheel delta {wheel_delta} at 30kph"
    print(f"live pedal data      ok (+{crank_delta} cranks, +{wheel_delta} wheel revs in 2s)")

    await host.send(ant_stick.MSG_REQUEST, [0, ant_stick.MSG_CHANNEL_ID])
    chan_id = await host.expect(ant_stick.MSG_CHANNEL_ID)
    dev_num, dev_type = struct.unpack_from("<HB", chan_id, 1)
    assert dev_type == ant_stick.DEV_CSC, f"wrong device type reported: {dev_type}"
    print(f"channel id report    ok (device #{dev_num}, type {dev_type})")

    # --- the trainer half: does terrain get back down to the bike? ---
    await host.send(ant_stick.MSG_ASSIGN_CHANNEL, [1, 0x00, 0])
    await host.expect(ant_stick.MSG_CHANNEL_RESPONSE)
    await host.send(ant_stick.MSG_CHANNEL_ID, [1, 0, 0, ant_stick.DEV_FEC, 0])
    await host.expect(ant_stick.MSG_CHANNEL_RESPONSE)
    await host.send(ant_stick.MSG_OPEN_CHANNEL, [1])
    await host.expect(ant_stick.MSG_CHANNEL_RESPONSE)

    pages = set()
    for _ in range(12):
        page = await host.expect(ant_stick.MSG_BROADCAST_DATA, timeout=5.0)
        if page[0] == 1:
            pages.add(page[1])
    assert ant_stick.PAGE_GENERAL_FE in pages, "trainer never sent the general page"
    assert ant_stick.PAGE_TRAINER_DATA in pages, "trainer never sent power data"
    print("trainer pages        ok (general + trainer data)")

    # Track resistance page: 6.5% climb. Raw grade is 0.01% steps from -200%.
    grade_raw = int((6.5 + 200.0) / 0.01)
    crr_raw = 80  # 0.004 in 0.00005 steps
    await host.send(
        ant_stick.MSG_ACK_DATA,
        bytes([1, ant_stick.PAGE_TRACK_RESISTANCE, 0xFF, 0xFF, 0xFF, 0xFF])
        + struct.pack("<HB", grade_raw, crr_raw),
    )
    for _ in range(20):
        if state.target_grade is not None:
            break
        await asyncio.sleep(0.1)
    assert state.target_grade is not None, "climb command was ignored"
    assert abs(state.target_grade - 6.5) < 0.05, f"grade decoded as {state.target_grade}"
    assert abs(state.target_crr - 0.004) < 0.0001, f"crr decoded as {state.target_crr}"
    print(f"climb command        ok ({state.target_grade:+.1f}% reaches the trainer)")

    # And a descent, to prove the sign survives the offset encoding
    await host.send(
        ant_stick.MSG_ACK_DATA,
        bytes([1, ant_stick.PAGE_TRACK_RESISTANCE, 0xFF, 0xFF, 0xFF, 0xFF])
        + struct.pack("<HB", int((-3.25 + 200.0) / 0.01), crr_raw),
    )
    for _ in range(20):
        if state.target_grade < 0:
            break
        await asyncio.sleep(0.1)
    assert abs(state.target_grade + 3.25) < 0.05, f"descent decoded as {state.target_grade}"
    print(f"descent command      ok ({state.target_grade:+.1f}% reaches the trainer)")

    await host.send(
        ant_stick.MSG_ACK_DATA,
        bytes([1, ant_stick.PAGE_TARGET_POWER] + [0xFF] * 5)
        + struct.pack("<H", 250 * 4),
    )
    for _ in range(20):
        if state.target_power:
            break
        await asyncio.sleep(0.1)
    assert state.target_power == 250, f"target power decoded as {state.target_power}"
    print(f"workout command      ok (hold {state.target_power:.0f}W)")

    writer.close()
    rider.cancel()
    server.close()
    print("\nall good - data goes up, resistance comes back down")


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except AssertionError as exc:
        print(f"\nFAILED: {exc}")
        sys.exit(1)
