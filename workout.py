"""Record a trainer session and turn it into something Strava will accept.

Samples once a second while a ride is running, then writes TCX. TCX rather
than FIT because it is plain XML - no library, nothing to go wrong, and Strava
takes it happily.
"""

import asyncio
import os
import time
from datetime import datetime, timedelta, timezone
from xml.sax.saxutils import escape

RIDES_DIR = os.path.expanduser("~/Documents/Wattline Rides")

TCX_HEAD = """<?xml version="1.0" encoding="UTF-8"?>
<TrainingCenterDatabase xmlns="http://www.garmin.com/xmlschemas/TrainingCenterDatabase/v2" \
xmlns:ns3="http://www.garmin.com/xmlschemas/ActivityExtension/v2">
 <Activities>
  <Activity Sport="Biking">
   <Id>{start}</Id>
   <Lap StartTime="{start}">
    <TotalTimeSeconds>{seconds:.0f}</TotalTimeSeconds>
    <DistanceMeters>{distance:.1f}</DistanceMeters>
    <MaximumSpeed>{max_speed:.3f}</MaximumSpeed>
    <Calories>{calories:.0f}</Calories>
    <Intensity>Active</Intensity>
    <TriggerMethod>Manual</TriggerMethod>
    <Track>
"""

TCX_TAIL = """    </Track>
   </Lap>
   <Creator xsi:type="Device_t" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
    <Name>{name}</Name>
   </Creator>
  </Activity>
 </Activities>
</TrainingCenterDatabase>
"""


class Ride:
    """One recorded session."""

    def __init__(self, state, name="Indoor ride"):
        self.state = state
        self.name = name
        self.samples = []  # (elapsed_s, power, cadence, hr, speed_kph, distance_m)
        self.started = None
        self.distance = 0.0
        self._task = None

    @property
    def running(self):
        return self._task is not None and not self._task.done()

    @property
    def elapsed(self):
        return (time.monotonic() - self.started) if self.started else 0.0

    @property
    def avg_power(self):
        watts = [s[1] for s in self.samples if s[1]]
        return sum(watts) / len(watts) if watts else 0

    def start(self):
        if self.running:
            return
        self.started = time.monotonic()
        self.start_wall = datetime.now(timezone.utc)
        self.samples.clear()
        self.distance = 0.0
        self._task = asyncio.create_task(self._sample_loop())

    async def _sample_loop(self):
        last = time.monotonic()
        while True:
            await asyncio.sleep(1.0)
            now = time.monotonic()
            s = self.state
            self.distance += (s.speed_kph or 0) / 3.6 * (now - last)
            last = now
            self.samples.append(
                (now - self.started, s.power, self._cadence(), s.hr, s.speed_kph, self.distance)
            )

    def _cadence(self):
        """Crank revolutions since the last sample, as rpm."""
        s = self.state
        prev = getattr(self, "_crank_prev", None)
        cur = (s.crank_revs, s.crank_time)
        self._crank_prev = cur
        if not prev or cur == prev:
            return 0
        d_rev = (cur[0] - prev[0]) & 0xFFFF
        d_time = (cur[1] - prev[1]) & 0xFFFF
        rpm = d_rev * 1024 * 60 / d_time if d_time else 0
        return int(rpm) if rpm < 250 else 0

    def stop(self):
        if self._task:
            self._task.cancel()
            self._task = None

    def to_tcx(self):
        start = self.start_wall.replace(microsecond=0).isoformat().replace("+00:00", "Z")
        speeds = [s[4] or 0 for s in self.samples]
        # 3.6 kJ per kcal at roughly 24% efficiency, the usual cycling estimate
        calories = self.avg_power * self.elapsed / 1000 / 4.184 / 0.24

        out = [
            TCX_HEAD.format(
                start=start,
                seconds=self.elapsed,
                distance=self.distance,
                max_speed=max(speeds, default=0) / 3.6,
                calories=calories,
            )
        ]
        for elapsed, power, cadence, hr, speed, distance in self.samples:
            stamp = self.start_wall + timedelta(seconds=elapsed)
            point = [f'     <Trackpoint><Time>{stamp.replace(microsecond=0).isoformat().replace("+00:00", "Z")}</Time>']
            point.append(f"<DistanceMeters>{distance:.1f}</DistanceMeters>")
            if cadence:
                point.append(f"<Cadence>{min(254, cadence)}</Cadence>")
            if hr:
                point.append(f"<HeartRateBpm><Value>{hr}</Value></HeartRateBpm>")
            ext = []
            if speed:
                ext.append(f"<ns3:Speed>{speed / 3.6:.3f}</ns3:Speed>")
            if power:
                ext.append(f"<ns3:Watts>{power}</ns3:Watts>")
            if ext:
                point.append(f'<Extensions><ns3:TPX>{"".join(ext)}</ns3:TPX></Extensions>')
            point.append("</Trackpoint>")
            out.append("".join(point) + "\n")

        out.append(TCX_TAIL.format(name=escape(self.name)))
        return "".join(out)

    def save(self):
        """Write the ride to disk and return the path."""
        os.makedirs(RIDES_DIR, exist_ok=True)
        stamp = self.start_wall.astimezone().strftime("%Y-%m-%d_%H-%M")
        path = os.path.join(RIDES_DIR, f"{stamp}.tcx")
        with open(path, "w") as fh:
            fh.write(self.to_tcx())
        return path


def demo():
    """Self-check: a fake ride produces TCX with the numbers in the right places."""
    import bike_ble

    state = bike_ble.BikeState()
    ride = Ride(state, name="Self check")
    ride.start_wall = datetime(2026, 6, 9, 10, 0, tzinfo=timezone.utc)
    ride.started = time.monotonic()
    ride.samples = [(float(i), 200 + i, 90, 140, 30.0, i * 8.3) for i in range(5)]
    ride.distance = 41.5

    xml = ride.to_tcx()
    assert "<ns3:Watts>204</ns3:Watts>" in xml, "power missing from trackpoints"
    assert "<Cadence>90</Cadence>" in xml, "cadence missing"
    assert "<HeartRateBpm><Value>140</Value>" in xml, "heart rate missing"
    assert xml.count("<Trackpoint>") == 5, "wrong number of trackpoints"
    assert "2026-06-09T10:00:04Z" in xml, "trackpoint timestamps are wrong"
    assert ride.avg_power == 202, f"average power computed as {ride.avg_power}"
    print("workout: TCX output ok")


if __name__ == "__main__":
    demo()
