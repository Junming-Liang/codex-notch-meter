#!/usr/bin/env python3
"""Independent 30-second, injected-source cache and own-view native gate."""
from copy import deepcopy
import json
import hashlib
import math
from pathlib import Path
import subprocess
import struct
import sys
sys.dont_write_bytecode = True

PREFIX = "MUSIC_RENDER_CACHE_JSON: "
GATE = "MUSIC_RENDER_CACHE_OK: independent=true deadline=30 realPolling=true boundedCache=true synthetic=true scanout=false"
SHUTDOWN = "SMOKE_OK: native island geometry, expansion and orderly shutdown completed; demo-only"
STEPS = (
    ("first", 1), ("repeat", 1), ("two-widths", 2), ("alternating", 2),
    ("third-width", 3), ("recent-hit", 3), ("evicted-width", 4), ("line", 5),
    ("next-present", 6), ("next-content", 6), ("track", 7),
    ("width-normalized", 8), ("normalized-hit", 8), ("clear", 9),
)
BOUNDARIES = ["freshness", "pause", "new-track", "disable", "sleep", "stop", "soft-failure"]
BOOLS = {
    "synthetic": True, "realPolling": True, "controllerOnly": False, "scanout": False,
    "fontStrategyEquivalent": True, "presentationRevisionUnchanged": True,
    "identicalImageReused": True, "sourceObservationAdvanced": True,
}
INTS = {
    "schema": 1, "deadlineSeconds": 30, "controllerWidthMeasurements": 2,
    "identicalPolls": 3, "publications": 0, "identicalImageBuilds": 1,
    "replacementBuilds": 3, "resumeBuilds": 4, "controllers": 6, "pendingRequests": 0,
}
INDICATOR_PNGS = [f"perimeter-indicator-{name}.png" for name in
                  ("playing-a", "playing-b", "paused", "reduced-motion")]
INDICATOR_BOOLS = dict(synthetic=True, ownPresentationLayerPixels=True, scanout=False,
                       loopEndpointsMatch=True, pausedStable=True, reduceMotionStable=True,
                       hiddenAncestorStopped=True, orderedOutStopped=True, detachedStopped=True,
                       dismantledStopped=True)
INDICATOR_INTS = dict(schema=2, changedBars=3, barCount=3, iconWidth=20, iconHeight=20,
                      unchangedUpdates=100, unchangedLayouts=100)
KEYS = set(BOOLS) | set(INTS) | {
    "elapsed", "layout", "freshnessAge", "latestPosition", "clearBoundaries", "readerCalls", "eventRecovery", "indicator",
}


def finite(value):
    return type(value) in (int, float) and math.isfinite(value)


def strict_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("duplicate JSON key")
        result[key] = value
    return result


def valid_hover_decision(value):
    return (isinstance(value, dict)
            and set(value) == {"timestamp", "inside", "expandedBefore", "expandedAfter"}
            and finite(value["timestamp"])
            and all(type(value[k]) is bool for k in ("inside", "expandedBefore", "expandedAfter"))
            and value["inside"] is True)


def valid_event_recovery(value):
    expected_bools = dict(syntheticPollLocation=True, nativeLocalEvents=True,
                          globalSystemDelivery=False, actualTimerPolling=True,
                          naturalPaint=True, noEnvelopeExit=True, unavailableLyrics=True)
    if not isinstance(value, dict) or set(value) != set(expected_bools) | {
        "eventRecoverySeconds", "firstPollQuietSeconds", "constructed", "sequence", "recoveryClock",
    }:
        return False
    if any(type(value[k]) is not bool or value[k] is not expected for k, expected in expected_bools.items()):
        return False
    if value["recoveryClock"] != "hover-decision-uptime":
        return False
    if not finite(value["eventRecoverySeconds"]) or not .12 <= value["eventRecoverySeconds"] < .8:
        return False
    if not finite(value["firstPollQuietSeconds"]) or not .25 < value["firstPollQuietSeconds"] < 1:
        return False
    events, sequence = value["constructed"], value["sequence"]
    if not isinstance(events, list) or len(events) != 9 or not isinstance(sequence, list) or len(sequence) != 5:
        return False
    def point(p):
        return isinstance(p, list) and len(p) == 2 and all(finite(n) for n in p)
    for i, event in enumerate(events):
        if not isinstance(event, dict) or set(event) != {
            "eventNumber", "eventType", "windowNumber", "requestedTimestamp", "constructedTimestamp",
            "deliveredTimestamp", "deliveredAt", "screenPoint", "localPoint", "owner", "target", "hoverDecision",
        }:
            return False
        if type(event["eventNumber"]) is not int or event["eventNumber"] != 28000 + i:
            return False
        if type(event["eventType"]) is not int or event["eventType"] != 5:
            return False
        if type(event["windowNumber"]) is not int or event["windowNumber"] <= 0:
            return False
        if not all(finite(event[k]) for k in ("requestedTimestamp", "constructedTimestamp", "deliveredTimestamp", "deliveredAt", "target")):
            return False
        if abs(event["requestedTimestamp"] - event["constructedTimestamp"]) >= 1e-9 or abs(event["constructedTimestamp"] - event["deliveredTimestamp"]) >= 1e-9:
            return False
        if event["deliveredAt"] < event["deliveredTimestamp"]:
            return False
        if not point(event["screenPoint"]) or not point(event["localPoint"]):
            return False
        if event["localPoint"] != [event["screenPoint"][0] + 900, event["screenPoint"][1] + 700]:
            return False
        if i and (event["windowNumber"] != events[0]["windowNumber"] or event["deliveredTimestamp"] <= events[i - 1]["deliveredTimestamp"]):
            return False
        if event["owner"] not in ("idle", "details") or event["target"] != (1 if event["owner"] == "details" else 0):
            return False
        decision = event["hoverDecision"]
        if i < 3:
            if decision is not None or event["owner"] != "idle":
                return False
        else:
            if (not valid_hover_decision(decision) or decision["timestamp"] < event["deliveredAt"]
                    or decision["expandedAfter"] != (event["owner"] == "details")):
                return False
            if i == 3:
                if decision["expandedBefore"] or decision["expandedAfter"]:
                    return False
            elif (decision["timestamp"] <= events[i - 1]["hoverDecision"]["timestamp"]
                  or events[i - 1]["hoverDecision"]["timestamp"] > event["deliveredAt"]
                  or decision["expandedBefore"] != events[i - 1]["hoverDecision"]["expandedAfter"]):
                return False
    endpoint = events[2]["screenPoint"]
    if any(event["screenPoint"] != endpoint for event in events[3:]):
        return False
    for i, (row, (kind, owner)) in enumerate(zip(sequence, (("event", "idle"), ("poll", "idle"), ("event", "idle"), ("event", "details"), ("poll", "details")))):
        if not isinstance(row, dict) or set(row) != {"kind", "owner", "target", "point", "timestamp", "hoverDecision"}:
            return False
        if row["kind"] != kind or row["owner"] != owner or row["point"] != endpoint:
            return False
        if not finite(row["target"]) or row["target"] != (1 if owner == "details" else 0) or not finite(row["timestamp"]):
            return False
        decision = row["hoverDecision"]
        if i == 0:
            if decision is not None:
                return False
        elif (not valid_hover_decision(decision) or decision["timestamp"] < row["timestamp"]
              or decision["expandedBefore"] != (i == 4) or decision["expandedAfter"] != (i >= 3)):
            return False
    if any(a["timestamp"] >= b["timestamp"] for a, b in zip(sequence, sequence[1:])):
        return False
    if sequence[0]["timestamp"] != events[2]["deliveredTimestamp"] or sequence[2]["timestamp"] != events[3]["deliveredTimestamp"]:
        return False
    details = next((e for e in events[4:] if e["owner"] == "details"), None)
    if details is None or details["deliveredTimestamp"] != sequence[3]["timestamp"]:
        return False
    for row, event in ((sequence[0], events[2]), (sequence[2], events[3]), (sequence[3], details)):
        if row["hoverDecision"] != event["hoverDecision"]:
            return False
    if any(a["hoverDecision"]["timestamp"] >= b["hoverDecision"]["timestamp"] for a, b in zip(sequence[1:], sequence[2:])):
        return False
    if (sequence[1]["hoverDecision"]["timestamp"] >= events[3]["deliveredAt"]
            or sequence[4]["timestamp"] <= events[-1]["hoverDecision"]["timestamp"]):
        return False
    if abs(sequence[1]["timestamp"] - events[2]["deliveredAt"] - value["firstPollQuietSeconds"]) > 1e-8:
        return False
    recovery = sequence[3]["hoverDecision"]["timestamp"] - sequence[1]["hoverDecision"]["timestamp"]
    if not .12 <= recovery < .8 or abs(recovery - value["eventRecoverySeconds"]) > 1e-8:
        return False
    if not .25 < sequence[4]["timestamp"] - events[-1]["deliveredAt"] < 1:
        return False
    return True


def valid_indicator(value):
    extra = {"elapsed", "sampleTimes", "scalesA", "scalesB", "changedBytes", "animationKey",
             "pixelWidth", "pixelHeight", "backingScale", "pngs", "deadlineSeconds", "periodSeconds",
             "observationDeadlineSeconds", "observationDuration", "observedRanges", "samples",
             "lifecycle", "samplePairIndices"}
    if not isinstance(value, dict) or set(value) != set(INDICATOR_BOOLS) | set(INDICATOR_INTS) | extra:
        return False
    if any(type(value[k]) is not bool or value[k] is not expected for k, expected in INDICATOR_BOOLS.items()):
        return False
    if any(type(value[k]) is not int or value[k] != expected for k, expected in INDICATOR_INTS.items()):
        return False
    if not finite(value["elapsed"]) or not 1.95 <= value["elapsed"] <= 3.0:
        return False
    if any(not finite(value[k]) or value[k] != expected for k, expected in
           (("deadlineSeconds", 3.0), ("periodSeconds", 1.6), ("observationDeadlineSeconds", 2.1))):
        return False
    if value["animationKey"] != "music.playing.scale" or value["pngs"] != INDICATOR_PNGS:
        return False
    scale = value["backingScale"]
    if not finite(scale) or not 1 <= scale <= 4:
        return False
    if any(type(value[k]) is not int or value[k] != round(40 * scale) for k in ("pixelWidth", "pixelHeight")):
        return False
    if type(value["changedBytes"]) is not int or not 0 < value["changedBytes"] <= value["pixelWidth"] * value["pixelHeight"] * 4:
        return False
    state_keys = {"time", "animationKeys", "animationStartCount", "windowVisible", "occlusionVisible", "attached", "hidden"}
    def state(row):
        return (finite(row["time"]) and 0 <= row["time"] < value["elapsed"]
                and type(row["animationStartCount"]) is int and row["animationStartCount"] >= 1
                and all(type(row[k]) is bool for k in ("windowVisible", "occlusionVisible", "attached", "hidden")))
    def vector(row, upper):
        return isinstance(row, list) and len(row) == 3 and all(finite(v) and 0 < v < upper for v in row)
    def digest(v):
        return isinstance(v, str) and len(v) == 64 and all(c in "0123456789abcdef" for c in v)
    running_keys = [[value["animationKey"]] for _ in range(3)]
    samples = value["samples"]
    # At 80 ms spacing the bounded 2.1 s observation can produce at most 28 rows.
    if not isinstance(samples, list) or not 3 <= len(samples) <= 28:
        return False
    for i, row in enumerate(samples):
        if not isinstance(row, dict) or set(row) != state_keys | {"scales", "heights", "pngSHA256"} or not state(row):
            return False
        if row["animationKeys"] != running_keys or not row["windowVisible"] or not row["occlusionVisible"] or not row["attached"] or row["hidden"]:
            return False
        if not vector(row["scales"], 1) or not vector(row["heights"], 14) or not digest(row["pngSHA256"]):
            return False
        if any(abs(h - 14 * scale) > 1e-5 for h, scale in zip(row["heights"], row["scales"])):
            return False
        if row["animationStartCount"] != samples[0]["animationStartCount"]:
            return False
        if i and row["time"] <= samples[i - 1]["time"]:
            return False
    if samples[0]["time"] < .14:
        return False
    duration = samples[-1]["time"] - samples[0]["time"]
    if not finite(value["observationDuration"]) or not 1.6 <= duration <= 2.1 or abs(value["observationDuration"] - duration) > 1e-8:
        return False
    ranges = value["observedRanges"]
    if not isinstance(ranges, list) or len(ranges) != 3:
        return False
    for i, span in enumerate(ranges):
        actual = max(row["scales"][i] for row in samples) - min(row["scales"][i] for row in samples)
        if not finite(span) or span <= .01 or abs(span - actual) > 1e-8:
            return False
    indices = value["samplePairIndices"]
    if not isinstance(indices, list) or len(indices) != 2 or any(type(i) is not int for i in indices):
        return False
    if indices[0] != 0 or not 0 < indices[1] < len(samples):
        return False
    first, second = (samples[i] for i in indices)
    times = value["sampleTimes"]
    if not isinstance(times, list) or len(times) != 2 or not all(finite(t) for t in times):
        return False
    if times != [first["time"], second["time"]] or second["time"] - first["time"] < .22:
        return False
    if value["scalesA"] != first["scales"] or value["scalesB"] != second["scales"] or first["pngSHA256"] == second["pngSHA256"]:
        return False
    if sum(abs(a - b) > .01 for a, b in zip(first["scales"], second["scales"])) != value["changedBars"]:
        return False
    stages = (("started", True, 0), ("unchanged-inputs", True, 0), ("observed-cycle", True, 0),
              ("paused", False, 0), ("resume-before-reduce-motion", True, 1), ("reduced-motion", False, 1),
              ("resume-after-reduce-motion", True, 2), ("ancestor-hidden", False, 2),
              ("ancestor-unhidden", True, 3), ("ordered-out", False, 3), ("ordered-front", True, 4),
              ("detached", False, 4), ("reattached", True, 5), ("dismantled", False, 5),
              ("dismantled-reconfigure", False, 5))
    lifecycle = value["lifecycle"]
    if not isinstance(lifecycle, list) or len(lifecycle) != len(stages):
        return False
    for i, (row, (name, running, increment)) in enumerate(zip(lifecycle, stages)):
        if not isinstance(row, dict) or set(row) != state_keys | {"stage"} or not state(row) or row["stage"] != name:
            return False
        if row["animationKeys"] != (running_keys if running else [[], [], []]):
            return False
        if row["animationStartCount"] != samples[0]["animationStartCount"] + increment:
            return False
        if row["hidden"] != (name == "ancestor-hidden") or row["attached"] != (name != "detached") or row["windowVisible"] != (name != "ordered-out"):
            return False
        if running and not row["occlusionVisible"]:
            return False
        if i and row["time"] < lifecycle[i - 1]["time"]:
            return False
    return lifecycle[1]["time"] <= samples[0]["time"] and lifecycle[2]["time"] >= samples[-1]["time"]


def valid_indicator_files(root, payload):
    directory = root / "dist/contour-rendering/indicator"
    try:
        images = [(directory / name).read_bytes() for name in INDICATOR_PNGS]
        expected = (payload["indicator"]["pixelWidth"], payload["indicator"]["pixelHeight"])
        indicator = payload["indicator"]
        chosen = [indicator["samples"][i]["pngSHA256"] for i in indicator["samplePairIndices"]]
        return all(len(data) > 33 and data[:8] == b"\x89PNG\r\n\x1a\n"
                   and data[12:16] == b"IHDR" and struct.unpack(">II", data[16:24]) == expected
                   for data in images) and images[0] != images[1] and [hashlib.sha256(data).hexdigest() for data in images[:2]] == chosen
    except (OSError, KeyError, IndexError, TypeError, struct.error):
        return False


def valid_payload(value):
    if not isinstance(value, dict) or set(value) != KEYS:
        return False
    if any(type(value[k]) is not bool or value[k] is not expected for k, expected in BOOLS.items()):
        return False
    if any(type(value[k]) is not int or value[k] != expected for k, expected in INTS.items()):
        return False
    if not finite(value["elapsed"]) or not 8 <= value["elapsed"] <= 30:
        return False
    if not finite(value["freshnessAge"]) or not 5 <= value["freshnessAge"] < 6.5:
        return False
    if not finite(value["latestPosition"]) or value["latestPosition"] != 4:
        return False
    if value["clearBoundaries"] != BOUNDARIES:
        return False
    if type(value["readerCalls"]) is not int or not 15 <= value["readerCalls"] <= 21:
        return False
    if not valid_event_recovery(value["eventRecovery"]) or not valid_indicator(value["indicator"]):
        return False
    rows = value["layout"]
    if not isinstance(rows, list) or len(rows) != len(STEPS):
        return False
    for row, (name, measurements) in zip(rows, STEPS):
        if not isinstance(row, dict) or set(row) != {"name", "measurements", "height", "uncachedHeight"}:
            return False
        if row["name"] != name or type(row["measurements"]) is not int or row["measurements"] != measurements:
            return False
        if not finite(row["height"]) or not finite(row["uncachedHeight"]):
            return False
        if row["height"] not in (48, 68, 70, 90) or row["height"] != row["uncachedHeight"]:
            return False
    return True


def valid(output):
    lines = output.splitlines()
    if any("FAILED" in line or "fatal error" in line.lower() for line in lines):
        return False
    selected = [line for line in lines if line.startswith("MUSIC_RENDER_CACHE_") or line.startswith("SMOKE_OK:")]
    if len(selected) != 3 or not selected[0].startswith(PREFIX) or selected[1:] != [GATE, SHUTDOWN]:
        return False
    if any(line != line.lstrip() and line.lstrip().startswith(("MUSIC_RENDER_CACHE_", "SMOKE_OK:")) for line in lines):
        return False
    if any(line.startswith(("MUSIC_OK:", "MUSIC_POINTER_GATE_OK:", "MUSIC_LYRICS_RECOVERY_DONE:")) for line in lines):
        return False
    try:
        data = json.loads(selected[0][len(PREFIX):], object_pairs_hook=strict_object,
                          parse_constant=lambda value: (_ for _ in ()).throw(ValueError(value)))
        return valid_payload(data)
    except (TypeError, ValueError, OverflowError):
        return False


def example():
    value = dict(BOOLS, **INTS)
    value.update(elapsed=15.2, freshnessAge=5.01, latestPosition=4.0, readerCalls=15,
                 clearBoundaries=BOUNDARIES,
                 layout=[dict(name=name, measurements=count, height=68, uncachedHeight=68) for name, count in STEPS])
    timestamps = [100, 100.04, 100.08, 100.36, 100.40, 100.44, 100.48, 100.52, 100.56]
    events = []
    for i, stamp in enumerate(timestamps):
        screen = [[388, 735], [512, 735], [636, 735]][min(i, 2)]
        events.append(dict(eventNumber=28000 + i, eventType=5, windowNumber=200,
                           requestedTimestamp=stamp, constructedTimestamp=stamp, deliveredTimestamp=stamp,
                           deliveredAt=stamp + .001, screenPoint=screen,
                           localPoint=[screen[0] + 900, screen[1] + 700],
                           owner="details" if i >= 6 else "idle", target=1 if i >= 6 else 0,
                           hoverDecision=None if i < 3 else dict(timestamp=stamp + .0015, inside=True,
                                                                expandedBefore=i > 6, expandedAfter=i >= 6)))
    sequence = [dict(kind=kind, owner=owner, target=1 if owner == "details" else 0,
                     point=[636, 735], timestamp=stamp)
                for kind, owner, stamp in (("event", "idle", 100.08), ("poll", "idle", 100.35),
                                           ("event", "idle", 100.36), ("event", "details", 100.48),
                                           ("poll", "details", 100.83))]
    for i, row in enumerate(sequence):
        if i in (0, 2, 3):
            row["hoverDecision"] = deepcopy(events[{0: 2, 2: 3, 3: 6}[i]]["hoverDecision"])
        else:
            row["hoverDecision"] = dict(timestamp=row["timestamp"] + .0005, inside=True,
                                        expandedBefore=i == 4, expandedAfter=i == 4)
    value["eventRecovery"] = dict(syntheticPollLocation=True, nativeLocalEvents=True,
                                  globalSystemDelivery=False, actualTimerPolling=True,
                                  naturalPaint=True, noEnvelopeExit=True, unavailableLyrics=True,
                                  eventRecoverySeconds=.131, firstPollQuietSeconds=.269,
                                  recoveryClock="hover-decision-uptime",
                                  constructed=events, sequence=sequence)
    value["indicator"] = dict(INDICATOR_BOOLS, **INDICATOR_INTS)
    indicator = value["indicator"]
    samples = []
    for i in range(21):
        scales = [.55 + .12 * math.sin(i * .31 + j * .4) for j in range(3)]
        samples.append(dict(time=.15 + i * .08, scales=scales, heights=[14 * x for x in scales],
                            pngSHA256=hashlib.sha256(str(i).encode()).hexdigest(),
                            animationKeys=[["music.playing.scale"] for _ in range(3)],
                            animationStartCount=1, windowVisible=True, occlusionVisible=True, attached=True, hidden=False))
    lifecycle = []
    for stage, running, increment, stamp in (
        ("started", True, 0, .01), ("unchanged-inputs", True, 0, .02), ("observed-cycle", True, 0, 1.76),
        ("paused", False, 0, 1.77), ("resume-before-reduce-motion", True, 1, 1.87), ("reduced-motion", False, 1, 1.91),
        ("resume-after-reduce-motion", True, 2, 2.01), ("ancestor-hidden", False, 2, 2.02),
        ("ancestor-unhidden", True, 3, 2.03), ("ordered-out", False, 3, 2.04), ("ordered-front", True, 4, 2.07),
        ("detached", False, 4, 2.08), ("reattached", True, 5, 2.09), ("dismantled", False, 5, 2.10),
        ("dismantled-reconfigure", False, 5, 2.11)):
        lifecycle.append(dict(stage=stage, time=stamp,
                              animationKeys=[["music.playing.scale"] for _ in range(3)] if running else [[], [], []],
                              animationStartCount=1 + increment, windowVisible=stage != "ordered-out",
                              occlusionVisible=stage != "ordered-out", attached=stage != "detached", hidden=stage == "ancestor-hidden"))
    indicator.update(elapsed=2.2, deadlineSeconds=3.0, periodSeconds=1.6, observationDeadlineSeconds=2.1,
                     samples=samples, lifecycle=lifecycle, samplePairIndices=[0, 3],
                     observationDuration=samples[-1]["time"] - samples[0]["time"],
                     observedRanges=[max(s["scales"][i] for s in samples) - min(s["scales"][i] for s in samples) for i in range(3)],
                     sampleTimes=[samples[0]["time"], samples[3]["time"]], scalesA=samples[0]["scales"], scalesB=samples[3]["scales"],
                     changedBytes=100, animationKey="music.playing.scale",
                     pixelWidth=80, pixelHeight=80, backingScale=2.0, pngs=INDICATOR_PNGS)
    return value


def output_for(value):
    return PREFIX + json.dumps(value, sort_keys=True) + "\n" + GATE + "\n" + SHUTDOWN + "\n"


def self_test():
    value = example(); output = output_for(value)
    assert valid(output)
    count = 1
    for key in value:
        bad = deepcopy(value); del bad[key]
        assert not valid(output_for(bad)), key; count += 1
        bad = deepcopy(value); bad[key] = None
        assert not valid(output_for(bad)), key; count += 1
    for key, expected in BOOLS.items():
        bad = deepcopy(value); bad[key] = not expected
        assert not valid(output_for(bad)), key; count += 1
    for key, expected in INTS.items():
        for replacement in (expected + 1, True, float(expected)):
            bad = deepcopy(value); bad[key] = replacement
            assert not valid(output_for(bad)), key; count += 1
    for index in range(len(STEPS)):
        for key, replacement in (("measurements", 99), ("height", 123), ("uncachedHeight", 48), ("name", "unknown")):
            bad = deepcopy(value); bad["layout"][index][key] = replacement
            assert not valid(output_for(bad)), (index, key); count += 1
    for key, replacements in {
        "elapsed": (7.999, 30.001, float("nan"), float("inf"), True),
        "freshnessAge": (4.999, 6.5, "5.1", True),
        "readerCalls": (14, 22, True), "latestPosition": (3, 5, True),
        "clearBoundaries": (BOUNDARIES[:-1], BOUNDARIES + ["extra"], list(reversed(BOUNDARIES))),
        "layout": (value["layout"][:-1], value["layout"] + [value["layout"][0]], list(reversed(value["layout"]))),
    }.items():
        for replacement in replacements:
            bad = deepcopy(value); bad[key] = replacement
            assert not valid(output_for(bad)), key; count += 1
    for line in output.splitlines():
        for bad in (output.replace(line + "\n", "", 1), output + line + "\n",
                    output.replace(line, " " + line, 1), output.replace(line, line + " garbage", 1)):
            assert not valid(bad); count += 1
    for suffix in ("MUSIC_RENDER_CACHE_EXTRA_OK: yes\n", "MUSIC_FAILED: failure\n",
                   "MUSIC_OK: unrelated\n", "fatal error: crash\n"):
        assert not valid(output + suffix); count += 1
    bad = output.replace('"schema": 1', '"schema": 1, "schema": 1')
    assert not valid(bad); count += 1
    bad = deepcopy(value); bad["extra"] = True
    assert not valid(output_for(bad)); count += 1
    for key, val in value["eventRecovery"].items():
        bad = deepcopy(value); del bad["eventRecovery"][key]
        assert not valid(output_for(bad)), key; count += 1
        bad = deepcopy(value); bad["eventRecovery"][key] = not val if type(val) is bool else None
        assert not valid(output_for(bad)), key; count += 1
    for i in range(9):
        for key, val in (("eventNumber", 1), ("eventType", 6), ("deliveredTimestamp", 1),
                         ("screenPoint", [1, 2]), ("windowNumber", -1), ("localPoint", [1, 2])):
            bad = deepcopy(value); bad["eventRecovery"]["constructed"][i][key] = val
            assert not valid(output_for(bad)), (i, key); count += 1
    for i in range(5):
        for key, val in (("kind", "synthetic"), ("target", 9), ("point", [1, 2]), ("timestamp", 1)):
            bad = deepcopy(value); bad["eventRecovery"]["sequence"][i][key] = val
            assert not valid(output_for(bad)), (i, key); count += 1
    for collection in ("constructed", "sequence"):
        for i, row in enumerate(value["eventRecovery"][collection]):
            bad = deepcopy(value); del bad["eventRecovery"][collection][i]["hoverDecision"]
            assert not valid(output_for(bad)), (collection, i, "missing-hover-decision"); count += 1
            decision = row["hoverDecision"]
            wrong_presence = None if decision is not None else value["eventRecovery"]["sequence"][1]["hoverDecision"]
            for replacement in (wrong_presence, False, {}, "monitor-time"):
                bad = deepcopy(value); bad["eventRecovery"][collection][i]["hoverDecision"] = replacement
                assert not valid(output_for(bad)), (collection, i, replacement); count += 1
            if decision is None:
                continue
            for key in decision:
                bad = deepcopy(value); del bad["eventRecovery"][collection][i]["hoverDecision"][key]
                assert not valid(output_for(bad)), (collection, i, key); count += 1
            for key, replacements in {
                "timestamp": (-1, True, float("nan"), float("inf")),
                "inside": (False, 1, "true"),
                "expandedBefore": (not decision["expandedBefore"], 0, None),
                "expandedAfter": (not decision["expandedAfter"], 1, None),
            }.items():
                for replacement in replacements:
                    bad = deepcopy(value); bad["eventRecovery"][collection][i]["hoverDecision"][key] = replacement
                    assert not valid(output_for(bad)), (collection, i, key, replacement); count += 1
    for clock in ("event-source-timestamp", "monitor-delivery-uptime", "hover-decision-uptime "):
        bad = deepcopy(value); bad["eventRecovery"]["recoveryClock"] = clock
        assert not valid(output_for(bad)), clock; count += 1
    for index in (2, 3):
        bad = deepcopy(value); bad["eventRecovery"]["sequence"][index]["hoverDecision"]["timestamp"] += .0001
        assert not valid(output_for(bad)), (index, "unbound-hover-decision"); count += 1
    # A source sample can fall just before the dwell boundary while the actual
    # hover decision occurs afterward. These are synthetic parser controls, not
    # reconstructed timestamps attributed to an old native run.
    edge = deepcopy(value)
    recovery = edge["eventRecovery"]
    recovery["sequence"][1]["timestamp"] = 100.3601
    recovery["sequence"][1]["hoverDecision"]["timestamp"] = 100.3602
    event = recovery["constructed"][3]
    event.update(requestedTimestamp=100.37, constructedTimestamp=100.37,
                 deliveredTimestamp=100.37, deliveredAt=100.371)
    event["hoverDecision"]["timestamp"] = 100.3715
    recovery["sequence"][2].update(timestamp=100.37, hoverDecision=deepcopy(event["hoverDecision"]))
    recovery["firstPollQuietSeconds"] = recovery["sequence"][1]["timestamp"] - recovery["constructed"][2]["deliveredAt"]
    recovery["eventRecoverySeconds"] = recovery["sequence"][3]["hoverDecision"]["timestamp"] - recovery["sequence"][1]["hoverDecision"]["timestamp"]
    assert recovery["sequence"][3]["timestamp"] - recovery["sequence"][1]["timestamp"] < .12
    assert valid(output_for(edge)); count += 1
    for delta in (recovery["sequence"][3]["timestamp"] - recovery["sequence"][1]["timestamp"],
                  recovery["constructed"][6]["deliveredAt"] - recovery["sequence"][1]["timestamp"]):
        bad = deepcopy(edge); bad["eventRecovery"]["eventRecoverySeconds"] = delta
        assert not valid(output_for(bad)), "source-or-monitor-proxy"; count += 1
    for delta, expected in ((.11999, False), (.12, True)):
        changed = deepcopy(edge); event_recovery = changed["eventRecovery"]
        event_recovery["sequence"][1]["hoverDecision"]["timestamp"] = event_recovery["sequence"][3]["hoverDecision"]["timestamp"] - delta
        actual = event_recovery["sequence"][3]["hoverDecision"]["timestamp"] - event_recovery["sequence"][1]["hoverDecision"]["timestamp"]
        event_recovery["eventRecoverySeconds"] = max(.12, actual)
        assert valid(output_for(changed)) is expected, (delta, actual); count += 1
    late = deepcopy(edge); event_recovery = late["eventRecovery"]
    for event in event_recovery["constructed"][6:]:
        for key in ("requestedTimestamp", "constructedTimestamp", "deliveredTimestamp", "deliveredAt"):
            event[key] += .7
        event["hoverDecision"]["timestamp"] += .7
    for row in event_recovery["sequence"][3:]:
        row["timestamp"] += .7; row["hoverDecision"]["timestamp"] += .7
    event_recovery["eventRecoverySeconds"] = .799
    assert not valid(output_for(late)), "actual-hover-delta-exceeds-upper-bound"; count += 1
    for key, val in value["indicator"].items():
        bad = deepcopy(value); del bad["indicator"][key]
        assert not valid(output_for(bad)), key; count += 1
        bad = deepcopy(value); bad["indicator"][key] = not val if type(val) is bool else None
        assert not valid(output_for(bad)), key; count += 1
    for key, replacements in {
        "schema": (True, 2.0, 1), "elapsed": (1.94, 3.001, float("inf")),
        "deadlineSeconds": (2.9, 3.1, True), "periodSeconds": (1.59, 1.61, True),
        "observationDeadlineSeconds": (2.0, 2.2, True), "observationDuration": (1.599, 2.101, True),
        "observedRanges": ([0, .2, .2], [.2, .2, .2], [True, .2, .2]),
        "samplePairIndices": ([0, 0], [0, 21], [True, 3], [1, 3]),
        "sampleTimes": ([.15, .36], [.15, .8], [True, .38]),
        "scalesA": ([.75, .51, .4], [0, .51, .4], [1, .51, .4]),
        "changedBars": (2, True), "changedBytes": (0, -1, True, 25601),
        "animationKey": ("wrong",), "pixelWidth": (79, True), "backingScale": (.5, 5, True),
        "pngs": (INDICATOR_PNGS[:-1], list(reversed(INDICATOR_PNGS))),
    }.items():
        for replacement in replacements:
            bad = deepcopy(value); bad["indicator"][key] = replacement
            assert not valid(output_for(bad)), (key, replacement); count += 1
    for collection in ("samples", "lifecycle"):
        for index in range(len(value["indicator"][collection])):
            for key in value["indicator"][collection][index]:
                bad = deepcopy(value); del bad["indicator"][collection][index][key]
                assert not valid(output_for(bad)), (collection, index, key); count += 1
            for key, replacement in (("animationKeys", [[], [], []]), ("animationStartCount", 999),
                                     ("windowVisible", None), ("time", -1), ("attached", None), ("hidden", None)):
                bad = deepcopy(value); bad["indicator"][collection][index][key] = replacement
                # A stopped lifecycle is deliberately required to have no keys.
                if key == "animationKeys" and value["indicator"][collection][index][key] == replacement:
                    continue
                assert not valid(output_for(bad)), (collection, index, key); count += 1
    for frozen in ((0,), (1,), (2,), (0, 1, 2)):
        bad = deepcopy(value); indicator = bad["indicator"]
        for row in indicator["samples"]:
            for i in frozen:
                row["scales"][i] = indicator["samples"][0]["scales"][i]
                row["heights"][i] = 14 * row["scales"][i]
        indicator["observedRanges"] = [max(s["scales"][i] for s in indicator["samples"]) - min(s["scales"][i] for s in indicator["samples"]) for i in range(3)]
        indicator["scalesA"] = indicator["samples"][0]["scales"]
        indicator["scalesB"] = indicator["samples"][3]["scales"]
        assert not valid(output_for(bad)), ("frozen-bars", frozen); count += 1
    for change in ("short-cycle", "late-cycle", "reordered", "same-pixels", "wrong-height", "restart", "interruption"):
        bad = deepcopy(value); indicator = bad["indicator"]; rows = indicator["samples"]
        if change == "short-cycle":
            rows.pop(); indicator["observationDuration"] = rows[-1]["time"] - rows[0]["time"]
        elif change == "late-cycle":
            rows[-1]["time"] = rows[0]["time"] + 2.101; indicator["observationDuration"] = 2.101
        elif change == "reordered": rows.reverse()
        elif change == "same-pixels": rows[3]["pngSHA256"] = rows[0]["pngSHA256"]
        elif change == "wrong-height": rows[2]["heights"][1] += 1
        elif change == "restart": rows[2]["animationStartCount"] += 1
        else: rows[2]["animationKeys"][1] = []
        assert not valid(output_for(bad)), change; count += 1
    # Bind the exact selected native samples to their exported A/B files.
    # These are explicit parser-only PNG fixtures, not application screenshots.
    import tempfile
    import zlib
    def fixture_png(color):
        def chunk(kind, content):
            return struct.pack(">I", len(content)) + kind + content + struct.pack(">I", zlib.crc32(kind + content) & 0xffffffff)
        raw = b"".join(b"\x00" + bytes(color) * 80 for _ in range(80))
        return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", 80, 80, 8, 6, 0, 0, 0)) + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b"")
    with tempfile.TemporaryDirectory(prefix="indicator-parser-") as temporary:
        root = Path(temporary); directory = root / "dist/contour-rendering/indicator"; directory.mkdir(parents=True)
        files = [fixture_png((i * 40, i * 20, i * 10, 255)) for i in range(4)]
        fixture = deepcopy(value)
        for name, data in zip(INDICATOR_PNGS, files):
            (directory / name).write_bytes(data)
        for sample_index, data in zip(fixture["indicator"]["samplePairIndices"], files[:2]):
            fixture["indicator"]["samples"][sample_index]["pngSHA256"] = hashlib.sha256(data).hexdigest()
        assert valid(output_for(fixture)) and valid_indicator_files(root, fixture); count += 1
        (directory / INDICATOR_PNGS[0]).write_bytes(files[0] + b"tampered")
        assert not valid_indicator_files(root, fixture); count += 1
        (directory / INDICATOR_PNGS[0]).write_bytes(files[1])
        assert not valid_indicator_files(root, fixture); count += 1
        (directory / INDICATOR_PNGS[0]).write_bytes(files[0])
        wrong_pair = deepcopy(fixture); wrong_pair["indicator"]["samples"][0]["pngSHA256"] = "0" * 64
        assert not valid_indicator_files(root, wrong_pair); count += 1
        (directory / INDICATOR_PNGS[3]).unlink()
        assert not valid_indicator_files(root, fixture); count += 1
    print(f"MUSIC_RENDER_CACHE_PARSER_SELF_TEST_OK: assertions={count} nativeAppRun=false")
    return 0


def main():
    if sys.argv[1:] == ["--self-test"]:
        return self_test()
    if len(sys.argv) == 3 and sys.argv[1] == "--validate-log":
        return 0 if valid(Path(sys.argv[2]).read_text()) else 1
    if len(sys.argv) > 2:
        print("usage: check-native-music-cache.py [APP_BINARY] | --self-test | --validate-log LOG", file=sys.stderr)
        return 2
    root = Path(__file__).resolve().parent.parent
    binary = Path(sys.argv[1]).resolve() if len(sys.argv) == 2 else root / "dist/Codex Notch Meter.app/Contents/MacOS/CodexNotchMeter"
    try:
        run = subprocess.run([str(binary), "--music-test", "--music-cache-test"],
                             capture_output=True, text=True, timeout=40, cwd=root)
    except OSError as error:
        print(f"MUSIC_RENDER_CACHE_FAILED: process-unavailable {error}", file=sys.stderr)
        return 1
    except subprocess.TimeoutExpired:
        print("MUSIC_RENDER_CACHE_FAILED: process-timeout", file=sys.stderr)
        return 1
    print(run.stdout, end="")
    print(run.stderr, end="", file=sys.stderr)
    if run.returncode != 0 or not valid(run.stdout):
        print("MUSIC_RENDER_CACHE_FAILED: invalid-native-evidence", file=sys.stderr)
        return 1
    receipt = next(line[len(PREFIX):] for line in run.stdout.splitlines() if line.startswith(PREFIX))
    if not valid_indicator_files(root, json.loads(receipt)):
        print("MUSIC_RENDER_CACHE_FAILED: missing-or-invalid-indicator-artifacts", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
