#!/usr/bin/env python3
"""Be the ANT+ aerial for a Mac that has none. Runs on the machine with a radio.

A Mac cannot receive ANT+ - not with a dongle in a hub, not at all, because
macOS has no ANT driver and the built-in radio is Bluetooth/Wi-Fi/Thread with
closed firmware. Anything else you own probably can: a Raspberry Pi, an old
Windows or Linux laptop, a spare SBC. Put the dongle there, run this, point it
at the Mac, and Wattline sees the sensors as if they were local.

    pip install openant
    ./wattline-relay.py --host wattline.local           # real ANT+ radio
    ./wattline-relay.py --host wattline.local --fake    # no radio, synthetic

Nine bytes per packet: one device type, then the sensor's eight. Nothing else
is on the wire, so writing your own relay for some other aerial is an evening,
not a project. Wattline must be started with --ant-relay-lan to listen to
anything but its own machine.
"""

import argparse
import math
import socket
import struct
import sys
import time

PORT = 51236

# The ANT+ profiles worth relaying. Anything else the dongle hears is ignored.
PROFILES = {"hr": 120, "power": 11, "speed_cadence": 121, "cadence": 122,
            "speed": 123, "trainer": 17}


def sender(host, port):
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    target = (host, port)

    def send(device_type, payload):
        if len(payload) != 8:
            return
        sock.sendto(bytes([device_type]) + bytes(payload), target)

    return send


def relay_real(send, log):
    """Hand every ANT+ broadcast we hear straight to Wattline.

    Untested against a real dongle - there is none on the machine this was
    written on. The openant API below is what its own examples use; if it has
    moved, this is the only part that needs fixing, and the wire format on the
    other side of it is fixed and simple.
    """
    from openant.easy.node import Node
    from openant.easy.channel import Channel
    from openant.base.commons import format_list  # noqa: F401 - import check

    node = Node()
    # The ANT+ network key ships with the openant package and comes from
    # registering as an ANT+ adopter at thisisant.com. It is not reproduced
    # here; openant.base.driver pulls in its own copy.
    from openant.devices import ANTPLUS_NETWORK_KEY

    node.set_network_key(0x00, ANTPLUS_NETWORK_KEY)
    channels = []
    for name, device_type in PROFILES.items():
        channel = node.new_channel(Channel.Type.BIDIRECTIONAL_RECEIVE)
        channel.set_period(8070)
        channel.set_search_timeout(255)
        channel.set_rf_freq(57)  # every ANT+ profile lives on 2457 MHz
        channel.set_id(0, device_type, 0)  # 0 = any device of this type
        channel.on_broadcast_data = lambda page, t=device_type: send(t, page)
        channel.on_burst_data = lambda page, t=device_type: send(t, page)
        channel.open()
        channels.append(channel)
        log(f"listening for {name} (device type {device_type})")

    log("relaying - ctrl-c to stop")
    try:
        node.start()
    finally:
        for channel in channels:
            channel.close()
        node.stop()


def relay_fake(send, log):
    """A rider who does not exist, for proving the path without a radio."""
    log("relaying a simulated rider - no radio in use")
    tick = 0.25
    wheel_m = 2.096  # 700x25c
    accumulated = events = 0
    crank_revs = wheel_revs = 0
    crank_frac = wheel_frac = 0.0
    crank_stamp = wheel_stamp = 0

    # Cadence and speed are counted in revolutions, so they have to advance at
    # a believable rate or the reader works out 480 rpm and discards it.
    while True:
        now = time.monotonic()
        power = int(200 + 40 * math.sin(now / 10))
        rpm = 90 + 5 * math.sin(now / 7)
        kph = 30.0

        accumulated = (accumulated + power) & 0xFFFF
        events = (events + 1) & 0xFF
        crank_frac += rpm / 60.0 * tick
        wheel_frac += (kph / 3.6 / wheel_m) * tick
        stamp = int(now * 1024) & 0xFFFF
        # The timestamp in these pages is when the last revolution happened,
        # not when the packet was sent. Stamping every packet with "now"
        # instead makes the reader divide a quantised revolution count by a
        # smooth clock, and it reads back a cadence that was never ridden.
        if crank_frac >= 1:
            crank_revs = (crank_revs + int(crank_frac)) & 0xFFFF
            crank_frac -= int(crank_frac)
            crank_stamp = stamp
        if wheel_frac >= 1:
            wheel_revs = (wheel_revs + int(wheel_frac)) & 0xFFFF
            wheel_frac -= int(wheel_frac)
            wheel_stamp = stamp

        # Cadence comes from the speed+cadence sensor here, so the power meter
        # sends 0xFF for it rather than two sources arguing over the cranks.
        send(PROFILES["power"],
             struct.pack("<BBBBHH", 0x10, events, 0xFF, 0xFF, accumulated, power))
        send(PROFILES["hr"],
             bytes([0x04, 0xFF, 0xFF, 0xFF]) + struct.pack("<HBB", stamp, events, 142))
        send(PROFILES["speed_cadence"],
             struct.pack("<HHHH", crank_stamp, crank_revs, wheel_stamp, wheel_revs))
        time.sleep(tick)


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--host", default="127.0.0.1", help="where Wattline is running")
    ap.add_argument("--port", type=int, default=PORT)
    ap.add_argument("--fake", action="store_true",
                    help="send a simulated rider instead of using a radio")
    args = ap.parse_args()

    def log(*parts):
        print(time.strftime("%H:%M:%S"), *parts, flush=True)

    send = sender(args.host, args.port)
    log(f"sending to {args.host}:{args.port}")
    try:
        (relay_fake if args.fake else relay_real)(send, log)
    except KeyboardInterrupt:
        print()
    except ImportError:
        log("openant is not installed here - `pip install openant`, or use --fake")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
