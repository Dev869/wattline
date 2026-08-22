"""Structured workouts: read a .zwo, flatten it, and drive the trainer through it.

Not to be confused with workout.py, which records a ride and writes TCX. This
is the other direction - a plan that tells the trainer what to do.

Only .zwo is supported. It is the format with thousands of files already out
there, it is plain XML, and its powers are fractions of FTP, which is the same
scale the graph needs anyway. The format is loose and was reverse-engineered
rather than published, so parsing is deliberately forgiving: unknown elements
become steady blocks at whatever power they mention, and missing attributes
fall back rather than raise.
"""

import asyncio
import json
import os
import time
import xml.etree.ElementTree as ET

CONFIG = os.path.expanduser("~/.config/wattline/config.json")

# Coggan's seven, as percentages of FTP. Zwift ships six and puts its
# boundaries elsewhere; nobody publishes official colours, so the daemon
# decides the zone and the overlay just draws what it is told.
ZONES = [0.55, 0.75, 0.90, 1.05, 1.20, 1.50]


def ftp():
    try:
        with open(CONFIG) as fh:
            return float(json.load(fh).get("ftp") or 200)
    except (OSError, ValueError, TypeError):
        return 200.0


def _config():
    try:
        with open(CONFIG) as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return {}


def _save(key, value):
    os.makedirs(os.path.dirname(CONFIG), exist_ok=True)
    data = _config()
    data[key] = value
    with open(CONFIG, "w") as fh:
        json.dump(data, fh)
    return value


def set_ftp(watts):
    return _save("ftp", int(watts))


def sources():
    """Which sensor each number is taken from: metric -> address.

    A metric nobody has picked is missing from the dict, which means "whatever
    offers it" - the right answer for a bike with one trainer on it.
    """
    picked = _config().get("sources") or {}
    return {k: v for k, v in picked.items() if isinstance(v, str) and v}


def set_source(metric, address):
    """Pick the sensor a number comes from, or None to take it from anything."""
    picked = sources()
    if address:
        picked[metric] = address
    else:
        picked.pop(metric, None)
    _save("sources", picked)
    return picked


def zone_of(watts, ftp_watts):
    """1-7. Used for the graph colours, so the app never guesses boundaries."""
    frac = watts / ftp_watts if ftp_watts else 0
    return sum(1 for edge in ZONES if frac > edge) + 1


class Step:
    __slots__ = ("duration", "p0", "p1", "cadence", "name")

    def __init__(self, duration, p0, p1=None, cadence=None, name=""):
        self.duration = max(1.0, float(duration))
        self.p0 = float(p0)
        self.p1 = float(p1 if p1 is not None else p0)
        self.cadence = cadence
        self.name = name

    def target_at(self, offset):
        """Watts this far into the step, interpolating ramps."""
        if self.p1 == self.p0:
            return self.p0
        return self.p0 + (self.p1 - self.p0) * min(1.0, offset / self.duration)


def _num(el, *names, default=None):
    for n in names:
        v = el.get(n)
        if v not in (None, ""):
            try:
                return float(v)
            except ValueError:
                pass
    return default


def parse_zwo(path, ftp_watts):
    """Flatten a .zwo into a list of Steps in watts.

    IntervalsT is expanded into its repeats here rather than at render time:
    everything downstream - the graph, the countdown, the executor - wants a
    flat timeline, and expanding once is cheaper than teaching each of them
    about repeats.
    """
    # Workouts get downloaded from the internet, so this is untrusted input.
    # ElementTree does not expand external entities, which leaves entity
    # amplification as the live risk; a real .zwo is a few kB, so a size cap
    # closes it without dragging in defusedxml for one parser.
    if os.path.getsize(path) > 1_000_000:
        raise ValueError("workout file is implausibly large, refusing to parse")
    root = ET.parse(path).getroot()
    name = (root.findtext("name") or os.path.basename(path)).strip()
    override = _num(root, "ftpOverride") or (
        float(root.findtext("ftpOverride")) if root.findtext("ftpOverride") else None
    )
    scale = override or ftp_watts

    steps = []
    block = root.find("workout")
    for el in list(block if block is not None else []):
        tag = el.tag
        dur = _num(el, "Duration", default=60.0)
        low = _num(el, "PowerLow", "Power", "PowerOn", default=None)
        high = _num(el, "PowerHigh", default=None)
        cad = _num(el, "Cadence")

        if tag == "IntervalsT":
            repeat = int(_num(el, "Repeat", default=1) or 1)
            on_d = _num(el, "OnDuration", default=60.0)
            off_d = _num(el, "OffDuration", default=60.0)
            on_p = _num(el, "OnPower", "PowerOnHigh", default=1.0)
            off_p = _num(el, "OffPower", "PowerOffHigh", default=0.5)
            on_c = _num(el, "Cadence")
            off_c = _num(el, "CadenceResting")
            for i in range(repeat):
                steps.append(Step(on_d, on_p * scale, cadence=on_c,
                                  name=f"Interval {i + 1}/{repeat}"))
                steps.append(Step(off_d, off_p * scale, cadence=off_c,
                                  name=f"Recovery {i + 1}/{repeat}"))
            continue

        if tag == "FreeRide":
            steps.append(Step(dur, 0, name="Free ride"))
            continue

        if tag == "MaxEffort":
            steps.append(Step(dur, 1.5 * scale, cadence=cad, name="Max effort"))
            continue

        # Warmup, Cooldown, Ramp and SteadyState all reduce to "hold, or slide
        # from one power to another over the block".
        start = (low if low is not None else 0.6) * scale
        end = (high if high is not None else low if low is not None else 0.6) * scale
        if tag in ("Warmup", "Ramp", "Cooldown") and high is not None and low is not None:
            steps.append(Step(dur, start, end, cad, name=tag))
        else:
            steps.append(Step(dur, start, cadence=cad, name=tag or "Block"))

    return name, steps


class Plan:
    """A loaded workout and where we are in it."""

    def __init__(self, name, steps, ftp_watts):
        self.name = name
        self.steps = steps
        self.ftp = ftp_watts
        self.total = sum(s.duration for s in steps)
        self.elapsed = 0.0
        self.running = False
        self._task = None
        self._last = None

    # -- position ---------------------------------------------------------

    def locate(self, at=None):
        """(index, offset into that step) for a point on the timeline."""
        t = self.elapsed if at is None else at
        for i, step in enumerate(self.steps):
            if t < step.duration:
                return i, t
            t -= step.duration
        return len(self.steps) - 1, self.steps[-1].duration if self.steps else 0

    @property
    def current(self):
        if not self.steps:
            return None
        return self.steps[self.locate()[0]]

    @property
    def upcoming(self):
        i = self.locate()[0]
        return self.steps[i + 1] if i + 1 < len(self.steps) else None

    @property
    def to_next(self):
        """Seconds until the target power changes."""
        i, off = self.locate()
        return max(0.0, self.steps[i].duration - off) if self.steps else 0.0

    @property
    def target(self):
        i, off = self.locate()
        return self.steps[i].target_at(off) if self.steps else 0.0

    @property
    def done(self):
        return self.elapsed >= self.total

    # -- execution --------------------------------------------------------

    def start(self, state):
        if self._task and not self._task.done():
            return
        self.running = True
        self._last = time.monotonic()
        self._task = asyncio.create_task(self._run(state))

    async def _run(self, state):
        while not self.done:
            await asyncio.sleep(0.5)
            now = time.monotonic()
            if self.running:
                self.elapsed += now - self._last
                # A free-ride block means "stop holding a target", not "0 W".
                target = self.target
                state.target_power = int(round(target)) if target > 0 else None
            self._last = now
        state.target_power = None
        self.running = False

    def pause(self):
        self.running = False
        self._last = time.monotonic()

    def resume(self):
        self._last = time.monotonic()
        self.running = True

    def skip(self):
        i, off = self.locate()
        self.elapsed += max(0.0, self.steps[i].duration - off) if self.steps else 0
        self._last = time.monotonic()

    def stop(self, state):
        self.running = False
        if self._task:
            self._task.cancel()
            self._task = None
        state.target_power = None

    # -- what the overlay draws ------------------------------------------

    def status(self):
        step, nxt = self.current, self.upcoming
        at = 0.0
        out_steps = []
        for s in self.steps:
            out_steps.append({
                "t": round(at, 1),
                "d": round(s.duration, 1),
                "p0": round(s.p0),
                "p1": round(s.p1),
                "zone": zone_of(max(s.p0, s.p1), self.ftp),
            })
            at += s.duration
        return {
            "name": self.name,
            "state": "running" if self.running else ("done" if self.done else "paused"),
            "elapsed": round(self.elapsed, 1),
            "total": round(self.total, 1),
            "target": round(self.target),
            "to_next": round(self.to_next, 1),
            "step": None if not step else {
                "name": step.name,
                "target": round(self.target),
                "remaining": round(self.to_next),
            },
            "next": None if not nxt else {
                "name": nxt.name,
                "target": round(nxt.p0),
                "d": round(nxt.duration),
            },
            "steps": out_steps,
        }


def load(path, ftp_watts=None):
    watts = ftp_watts or ftp()
    name, steps = parse_zwo(os.path.expanduser(path), watts)
    if not steps:
        raise ValueError("no workout steps in that file")
    return Plan(name, steps, watts)


def demo():
    """Self-check: a known .zwo flattens to the timeline we expect."""
    import tempfile

    sample = """<workout_file>
      <name>Check</name>
      <workout>
        <Warmup Duration="300" PowerLow="0.4" PowerHigh="0.8"/>
        <IntervalsT Repeat="3" OnDuration="60" OffDuration="30"
                    OnPower="1.2" OffPower="0.5"/>
        <SteadyState Duration="120" Power="0.9" Cadence="95"/>
        <FreeRide Duration="60"/>
        <Cooldown Duration="180" PowerHigh="0.6" PowerLow="0.3"/>
      </workout>
    </workout_file>"""
    with tempfile.NamedTemporaryFile("w", suffix=".zwo", delete=False) as fh:
        fh.write(sample)
        path = fh.name

    plan = load(path, ftp_watts=200)
    os.unlink(path)

    assert plan.name == "Check", plan.name
    # warmup + 3x(on,off) + steady + freeride + cooldown
    assert len(plan.steps) == 1 + 6 + 1 + 1 + 1, f"{len(plan.steps)} steps"
    assert plan.total == 300 + 3 * 90 + 120 + 60 + 180, plan.total

    warm = plan.steps[0]
    assert (warm.p0, warm.p1) == (80.0, 160.0), (warm.p0, warm.p1)
    assert warm.target_at(0) == 80 and warm.target_at(300) == 160, "ramp not interpolating"
    assert round(warm.target_at(150)) == 120, warm.target_at(150)

    assert plan.steps[1].p0 == 240.0, plan.steps[1].p0   # 1.2 x 200
    assert plan.steps[2].p0 == 100.0, plan.steps[2].p0   # 0.5 x 200
    assert plan.steps[1].name == "Interval 1/3", plan.steps[1].name

    plan.elapsed = 300
    assert plan.current.name == "Interval 1/3", plan.current.name
    assert plan.target == 240, plan.target
    assert plan.to_next == 60, plan.to_next
    assert plan.upcoming.name == "Recovery 1/3", plan.upcoming.name

    plan.skip()
    assert plan.current.name == "Recovery 1/3", plan.current.name

    # 50% FTP is recovery; 120% is the top of zone 5, not the bottom of 6.
    assert zone_of(100, 200) == 1, zone_of(100, 200)
    assert zone_of(160, 200) == 3, zone_of(160, 200)
    assert zone_of(240, 200) == 5, zone_of(240, 200)
    assert zone_of(320, 200) == 7, zone_of(320, 200)
    st = plan.status()
    assert len(st["steps"]) == len(plan.steps) and st["steps"][0]["t"] == 0
    print("plan: zwo parse, ramps, intervals, zones ok")


if __name__ == "__main__":
    demo()
