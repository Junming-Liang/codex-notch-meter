#!/usr/bin/env python3
"""Independent 30-second, injected-source cache and own-view native gate."""
from copy import deepcopy
import json
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
INDICATOR_INTS = dict(schema=1, changedBars=3, barCount=3, iconWidth=20, iconHeight=20,
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


def valid_event_recovery(value):
    expected_bools = dict(syntheticPollLocation=True, nativeLocalEvents=True,
                          globalSystemDelivery=False, actualTimerPolling=True,
                          naturalPaint=True, noEnvelopeExit=True, unavailableLyrics=True)
    if not isinstance(value, dict) or set(value) != set(expected_bools) | {
        "eventRecoverySeconds", "firstPollQuietSeconds", "constructed", "sequence",
    }:
        return False
    if any(type(value[k]) is not bool or value[k] is not expected for k, expected in expected_bools.items()):
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
            "deliveredTimestamp", "deliveredAt", "screenPoint", "localPoint", "owner", "target",
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
    endpoint = events[2]["screenPoint"]
    if any(event["screenPoint"] != endpoint for event in events[3:]):
        return False
    for row, (kind, owner) in zip(sequence, (("event", "idle"), ("poll", "idle"), ("event", "idle"), ("event", "details"), ("poll", "details"))):
        if not isinstance(row, dict) or set(row) != {"kind", "owner", "target", "point", "timestamp"}:
            return False
        if row["kind"] != kind or row["owner"] != owner or row["point"] != endpoint:
            return False
        if not finite(row["target"]) or row["target"] != (1 if owner == "details" else 0) or not finite(row["timestamp"]):
            return False
    if any(a["timestamp"] >= b["timestamp"] for a, b in zip(sequence, sequence[1:])):
        return False
    if sequence[0]["timestamp"] != events[2]["deliveredTimestamp"] or sequence[2]["timestamp"] != events[3]["deliveredTimestamp"]:
        return False
    if not any(e["deliveredTimestamp"] == sequence[3]["timestamp"] and e["owner"] == "details" for e in events[4:]):
        return False
    if abs(sequence[1]["timestamp"] - events[2]["deliveredAt"] - value["firstPollQuietSeconds"]) > 1e-8:
        return False
    if abs(sequence[3]["timestamp"] - sequence[1]["timestamp"] - value["eventRecoverySeconds"]) > 1e-8:
        return False
    if not .25 < sequence[4]["timestamp"] - events[-1]["deliveredAt"] < 1:
        return False
    return True


def valid_indicator(value):
    if not isinstance(value, dict) or set(value) != set(INDICATOR_BOOLS) | set(INDICATOR_INTS) | {
        "elapsed", "sampleTimes", "scalesA", "scalesB", "changedBytes", "animationKey",
        "pixelWidth", "pixelHeight", "backingScale", "pngs",
    }:
        return False
    if any(type(value[k]) is not bool or value[k] is not expected for k, expected in INDICATOR_BOOLS.items()):
        return False
    if any(type(value[k]) is not int or value[k] != expected for k, expected in INDICATOR_INTS.items()):
        return False
    if not finite(value["elapsed"]) or not .54 <= value["elapsed"] < 1.9:
        return False
    times = value["sampleTimes"]
    if not isinstance(times, list) or len(times) != 2 or not all(finite(v) for v in times):
        return False
    if not .14 <= times[0] < times[1] < value["elapsed"] or times[1] - times[0] < .22:
        return False
    for key in ("scalesA", "scalesB"):
        if not isinstance(value[key], list) or len(value[key]) != 3 or not all(finite(v) and 0 < v < 1 for v in value[key]):
            return False
    if sum(abs(a - b) > .01 for a, b in zip(value["scalesA"], value["scalesB"])) != value["changedBars"]:
        return False
    scale = value["backingScale"]
    if not finite(scale) or not 1 <= scale <= 4:
        return False
    if any(type(value[k]) is not int or value[k] != round(40 * scale) for k in ("pixelWidth", "pixelHeight")):
        return False
    if type(value["changedBytes"]) is not int or not 0 < value["changedBytes"] <= value["pixelWidth"] * value["pixelHeight"] * 4:
        return False
    return value["animationKey"] == "music.playing.scale" and value["pngs"] == INDICATOR_PNGS


def valid_indicator_files(root, payload):
    directory = root / "dist/contour-rendering/indicator"
    try:
        images = [(directory / name).read_bytes() for name in INDICATOR_PNGS]
        expected = (payload["indicator"]["pixelWidth"], payload["indicator"]["pixelHeight"])
        return all(len(data) > 33 and data[:8] == b"\x89PNG\r\n\x1a\n"
                   and data[12:16] == b"IHDR" and struct.unpack(">II", data[16:24]) == expected
                   for data in images) and images[0] != images[1]
    except (OSError, KeyError, struct.error):
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
                           owner="details" if i >= 6 else "idle", target=1 if i >= 6 else 0))
    sequence = [dict(kind=kind, owner=owner, target=1 if owner == "details" else 0,
                     point=[636, 735], timestamp=stamp)
                for kind, owner, stamp in (("event", "idle", 100.08), ("poll", "idle", 100.35),
                                           ("event", "idle", 100.36), ("event", "details", 100.48),
                                           ("poll", "details", 100.83))]
    value["eventRecovery"] = dict(syntheticPollLocation=True, nativeLocalEvents=True,
                                  globalSystemDelivery=False, actualTimerPolling=True,
                                  naturalPaint=True, noEnvelopeExit=True, unavailableLyrics=True,
                                  eventRecoverySeconds=.13, firstPollQuietSeconds=.269,
                                  constructed=events, sequence=sequence)
    value["indicator"] = dict(INDICATOR_BOOLS, **INDICATOR_INTS)
    value["indicator"].update(elapsed=.8, sampleTimes=[.15, .38], scalesA=[.51, .79, .56],
                              scalesB=[.75, .51, .40], changedBytes=100, animationKey="music.playing.scale",
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
    for key, val in value["indicator"].items():
        bad = deepcopy(value); del bad["indicator"][key]
        assert not valid(output_for(bad)), key; count += 1
        bad = deepcopy(value); bad["indicator"][key] = not val if type(val) is bool else None
        assert not valid(output_for(bad)), key; count += 1
    for key, replacements in {
        "schema": (True, 1.0, 2), "elapsed": (.53, 1.9, float("inf")),
        "sampleTimes": ([.15, .36], [.15, .8], [True, .38]),
        "scalesA": ([.75, .51, .4], [0, .51, .4], [1, .51, .4]),
        "changedBars": (2, True), "changedBytes": (0, -1, True, 25601),
        "animationKey": ("wrong",), "pixelWidth": (79, True), "backingScale": (.5, 5, True),
        "pngs": (INDICATOR_PNGS[:-1], list(reversed(INDICATOR_PNGS))),
    }.items():
        for replacement in replacements:
            bad = deepcopy(value); bad["indicator"][key] = replacement
            assert not valid(output_for(bad)), (key, replacement); count += 1
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
