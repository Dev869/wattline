"""Take ANT+ pages off the network, because this Mac has no ANT+ radio.

No Mac does. The radio in an Apple silicon machine speaks Bluetooth, Wi-Fi and
Thread, and its firmware is closed - there is no way to make it receive ANT+,
and no USB stick here to do it instead. But the decoding is ours (see ant.py),
so anything that *does* have an ANT+ radio can be the aerial and send the bytes
over: a phone, a Raspberry Pi, an old head unit, a spare laptop with a dongle
already in it.

The wire format is deliberately the smallest thing a relay could send - nine
bytes, one datagram per broadcast:

    +-------------------+---------------------------+
    | device type (1)   | ANT+ page payload (8)     |
    +-------------------+---------------------------+

so writing a relay is a dozen lines in whatever language the aerial happens to
speak. Localhost only unless you ask otherwise, because listening to the whole
network for packets that move a number on your screen is not a default.
"""

import asyncio
import time

import ant

RELAY_PORT = 51236
PACKET_SIZE = 9

# A relay that stops sending stops being a sensor. This is how long a quiet
# relay stays in the sensor list before it is treated as gone.
RELAY_TTL = 10.0


class RelayProtocol(asyncio.DatagramProtocol):
    """Nine bytes in, one sensor reading out. Anything else is dropped."""

    def __init__(self, state, log=print):
        self.state, self.log = state, log
        self.seen = {}  # device type -> last packet time
        self.complained = set()

    def datagram_received(self, data, addr):
        if len(data) != PACKET_SIZE:
            self._complain(f"ignoring a {len(data)}-byte datagram from {addr[0]}")
            return
        device_type, payload = data[0], data[1:]
        try:
            read = ant.apply(self.state, device_type, payload)
        except ant.AntError as exc:
            self._complain(f"{addr[0]}: {exc}")
            return

        if device_type not in self.seen:
            name = ant.DEVICE_NAMES.get(device_type, f"type {device_type}")
            self.log(f"ANT+ relay from {addr[0]}: {name}")
        self.seen[device_type] = time.monotonic()
        if read:
            self.state.sensors[self._name(device_type)] = ["relayed"]

    def expire(self):
        """Drop relays that have gone quiet.

        On a timer rather than off the back of an arriving packet: a relay that
        stops sending is exactly the case that matters, and it is also the case
        where no packet is coming to trigger the check. Unplug the aerial and
        its sensors have to leave the list on their own.
        """
        now = time.monotonic()
        for device_type, last in list(self.seen.items()):
            if now - last > RELAY_TTL:
                del self.seen[device_type]
                self.state.sensors.pop(self._name(device_type), None)
                self.log(f"ANT+ relay stopped sending {ant.DEVICE_NAMES.get(device_type, device_type)}")

    @staticmethod
    def _name(device_type):
        """Named apart from the Bluetooth sensors, since they can both be on."""
        return f"ANT+ {ant.DEVICE_NAMES.get(device_type, device_type)}"

    def _complain(self, message):
        """Say it once. A misconfigured relay sends junk four times a second."""
        if message not in self.complained:
            self.complained.add(message)
            self.log(message)


async def listen(state, lan=False, log=print):
    host = "0.0.0.0" if lan else "127.0.0.1"
    loop = asyncio.get_running_loop()
    _, protocol = await loop.create_datagram_endpoint(
        lambda: RelayProtocol(state, log), local_addr=(host, RELAY_PORT)
    )
    where = "the network" if lan else "localhost"
    log(f"listening for ANT+ relays on {host}:{RELAY_PORT} ({where})")
    asyncio.create_task(_expire_loop(protocol))
    return protocol


async def _expire_loop(protocol, every=1.0):
    while True:
        await asyncio.sleep(every)
        protocol.expire()
