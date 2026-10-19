#!/usr/bin/env python3
"""Own-process queued AppKit events only; no input taps or system posting."""
from pathlib import Path
import re
import json
import subprocess
import sys

NUM = r"([0-9]+(?:\.[0-9]+)?)"
INPUT = ("MUSIC_NATIVE_INPUT_OK: localEventQueue=true globalSystemDelivery=false "
         "queuedPoints=true originalTimestamps=true windowCoordinates=true nilWindowCoordinates=true "
         "negativeOrigin=true lowerBand=true slowReverse=true noMovingDetails=true stationaryHover=true "
         "fixedHoverAnchor=true equalTimestampButtons=true heldButtons=true postedEvents=")
GATE = "MUSIC_POINTER_GATE_OK: independent=true deadline=45 oldMusicDeadline=150 closedHeightMask=true nativeEventQueue=true"

def valid(output):
    def one(pattern):
        rows = re.findall("^" + pattern + "$", output, re.MULTILINE)
        return rows[0] if len(rows) == 1 else None
    if "FAILED" in output or output.count(GATE) != 1:
        return False
    events = one(re.escape(INPUT) + r"(\d+)")
    height = one(r"MUSIC_CLOSED_HEIGHT_MASK_OK: skins=5 sameHeight=true sameBottom=true widthOnly=true owner=idle rawMaskParity=true maxAlphaDifference="
                 + NUM + r" visibleBottomPoints=" + NUM + r" actualBacking=([12]) ownViewPixels=true physicalMaskVerified=false scanout=false")
    frames = re.findall(r"^MUSIC_RENDER_COMMIT_OK: label=(closed-transitions|native-input) allPaintsMatched=true historyOverflow=false orderedRevisions=true nativeFrameMatched=true commits=(\d+) paints=(\d+) distinctPaintRevisions=(\d+) maxLatencyMs=" + NUM + r" scanout=false$", output, re.MULTILINE)
    segments = re.findall(r"^MUSIC_GESTURE_SEGMENT_OK: segment=(window-open|slow-reverse-close|screen-open|screen-close) commits=(\d+) movingPaintRevisions=(\d+) monotonicProgress=true monotonicDimensions=true fixedAnchor=true endpoint=true$", output, re.MULTILINE)
    final = one(r"MUSIC_OK: checks=(\d+) elapsed=" + NUM + r" synthetic=true localViewPixels=true scanout=false")
    transition = re.findall(r"^MUSIC_CLOSED_TRANSITION_HEIGHT_OK: transition=(playback-start|pause|reconnect) commits=(\d+) movingCommits=(\d+) paints=(\d+) movingPaints=(\d+) sameHeight=true sameBottom=true widthOnly=true scanout=false$", output, re.MULTILINE)
    if not events or not height or not frames or not final:
        return False
    if int(events) < 12 or float(height[0]) > 2 / 255 or float(height[1]) <= 0:
        return False
    if len(frames) != 2 or {x[0] for x in frames} != {"closed-transitions", "native-input"}:
        return False
    if any(min(map(int, x[1:4])) < 2 for x in frames):
        return False
    if len(segments) != 4 or len({x[0] for x in segments}) != 4 or any(int(x[1]) < 3 or int(x[2]) < 2 for x in segments):
        return False
    if int(final[0]) < 20 or not 0 < float(final[1]) <= 45:
        return False
    if len(transition) != 3 or {x[0] for x in transition} != {"playback-start", "pause", "reconnect"}:
        return False
    if any(int(x[1]) < 3 or int(x[2]) < 3 or int(x[3]) < 2 or int(x[4]) < 2 for x in transition):
        return False
    trace_line = one(r"MUSIC_POINTER_TRACE_JSON: (.+)")
    if not trace_line or len(trace_line) >= 1_000_000:
        return False
    try:
        trace = json.loads(trace_line)
        if trace["localEventQueue"] is not True or trace["globalSystemDelivery"] is not False or trace["historyOverflow"] is not False or trace["paintHistoryOverflow"] is not False:
            return False
        commits = {x["revision"]: x for x in trace["commits"]}
        if len(commits) < 2 or len(commits) != len(trace["commits"]) or len(trace["events"]) < 12:
            return False
        paints = [p for p in trace["paints"] if p["revision"] > 0]
        if len(paints) < 2:
            return False
        for p in paints:
            c = commits[p["revision"]]
            if p["nativeFrameSampledAtPaint"] is not True or p["nativeFrame"] != c["frame"] or p["progress"] != c["progress"] or p["accessory"] != c["accessory"] or p["observed"] < c["observed"]:
                return False
            if p["viewport"] != c["frame"][2:] or p["actualViewport"] != c["frame"][2:] or p["nativeContentBounds"] != [0, 0] + c["frame"][2:]:
                return False
        if any(b["revision"] < a["revision"] or b["sequence"] <= a["sequence"] for a, b in zip(paints, paints[1:])):
            return False
    except (ValueError, KeyError, TypeError):
        return False
    shutdown = "SMOKE_OK: synthetic orderly shutdown"
    return output.count(shutdown) == 1 and output.index(shutdown) > output.index("MUSIC_OK:")

def sample():
    commits = [{"revision": i, "observed": i, "progress": 0.1 * i, "accessory": 1, "frame": [10, 20, 300, 40]} for i in (1, 2)]
    paints = [{"revision": c["revision"], "sequence": c["revision"], "observed": c["observed"] + 0.01,
               "progress": c["progress"], "accessory": 1, "nativeFrameSampledAtPaint": True,
               "nativeFrame": c["frame"], "viewport": [300, 40], "actualViewport": [300, 40],
               "nativeContentBounds": [0, 0, 300, 40]} for c in commits]
    trace = {"localEventQueue": True, "globalSystemDelivery": False, "historyOverflow": False,
             "paintHistoryOverflow": False, "events": [{}] * 40, "commits": commits, "paints": paints}
    return "\n".join([
        INPUT + "40",
        "MUSIC_POINTER_TRACE_JSON: " + json.dumps(trace, separators=(",", ":")),
        "MUSIC_CLOSED_HEIGHT_MASK_OK: skins=5 sameHeight=true sameBottom=true widthOnly=true owner=idle rawMaskParity=true maxAlphaDifference=0.0 visibleBottomPoints=3.0 actualBacking=2 ownViewPixels=true physicalMaskVerified=false scanout=false",
        *[f"MUSIC_RENDER_COMMIT_OK: label={label} allPaintsMatched=true historyOverflow=false orderedRevisions=true nativeFrameMatched=true commits=90 paints=100 distinctPaintRevisions=30 maxLatencyMs=20.0 scanout=false" for label in ("closed-transitions", "native-input")],
        *[f"MUSIC_GESTURE_SEGMENT_OK: segment={name} commits=30 movingPaintRevisions=20 monotonicProgress=true monotonicDimensions=true fixedAnchor=true endpoint=true" for name in ("window-open", "slow-reverse-close", "screen-open", "screen-close")],
        *[f"MUSIC_CLOSED_TRANSITION_HEIGHT_OK: transition={t} commits=20 movingCommits=18 paints=19 movingPaints=17 sameHeight=true sameBottom=true widthOnly=true scanout=false" for t in ("playback-start", "pause", "reconnect")],
        GATE,
        "MUSIC_OK: checks=200 elapsed=21.5 synthetic=true localViewPixels=true scanout=false",
        "SMOKE_OK: synthetic orderly shutdown",
    ]) + "\n"

def self_test():
    text = sample()
    assert valid(text)
    count = 1
    for line in text.splitlines():
        assert not valid(text.replace(line + "\n", ""))
        assert not valid(text + line + "\n")
        count += 2
    for a, b in [("=true", "=false"), ("globalSystemDelivery=false", "globalSystemDelivery=true"),
                 ("historyOverflow=false", "historyOverflow=true"),
                 ('"nativeFrameSampledAtPaint":true', '"nativeFrameSampledAtPaint":false'),
                 ('"nativeContentBounds":[0,0,300,40]', '"nativeContentBounds":[0,0,300,41]'), ("postedEvents=40", "postedEvents=2"),
                 ("maxAlphaDifference=0.0", "maxAlphaDifference=0.1"), ("visibleBottomPoints=3.0", "visibleBottomPoints=0"),
                 ("movingCommits=18", "movingCommits=2"), ("movingPaints=17", "movingPaints=1"),
                 ("movingPaintRevisions=20", "movingPaintRevisions=1"), ("elapsed=21.5", "elapsed=45.1")]:
        assert not valid(text.replace(a, b)), a
        count += 1
    assert not valid(text + "MUSIC_FAILED: injected\n")
    print(f"POINTER_RECEIPT_SELF_TEST_OK: assertions={count + 1} nativeAppRun=false")
    return 0

def main():
    if sys.argv[1:] == ["--self-test"]:
        return self_test()
    root = Path(__file__).resolve().parent.parent
    executable = root / "dist/Codex Notch Meter.app/Contents/MacOS/CodexNotchMeter"
    try:
        child = subprocess.Popen([str(executable), "--music-test", "--pointer-ingress-test"],
                                 cwd=root, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    except OSError as error:
        print(f"Native pointer gate could not start: {error}", file=sys.stderr)
        return 1
    timed_out = False
    try:
        stdout, stderr = child.communicate(timeout=55)
    except subprocess.TimeoutExpired:
        timed_out = True
        child.kill()
        try:
            stdout, stderr = child.communicate(timeout=5)
        except subprocess.TimeoutExpired:
            print("Owned native pointer child cleanup exceeded 5 seconds.", file=sys.stderr)
            return 1
    print(stdout, end="")
    print(stderr, end="", file=sys.stderr)
    if timed_out or child.returncode != 0 or not valid(stdout):
        print("Native queued pointer/closed-height contract failed.", file=sys.stderr)
        return 1
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
