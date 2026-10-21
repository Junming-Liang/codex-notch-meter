#!/usr/bin/env python3
"""Validate the wide-music-shell quota-hover native regression, not real Music."""
import copy
import json
import hashlib
import io
import tarfile
import tempfile
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
BASELINE = "17e3fef35ac89dda5588620009564558136270b6"
FLAGS = ["--music-test", "--music-cache-test", "--music-stationary-hover-test", "--music-wide-quota-hover-test"]
PREFIX = "MUSIC_WIDE_QUOTA_HOVER_JSON: "
OK = "MUSIC_WIDE_QUOTA_HOVER_OK: nativeLocal=true naturalPoll=true synthetic=true"
RED_FAILURE = "MUSIC_STATIONARY_HOVER_FAILED: wide-music-quota-settled"
RED_SHUTDOWN = "SMOKE_FAILED: native island checks failed"
SHUTDOWN = "SMOKE_OK: native island geometry, expansion and orderly shutdown completed; demo-only"


def need(value, label):
    if not value:
        raise ValueError(label)


def validate(log):
    lines = log.splitlines()
    need(lines.count(OK) == 1 and lines.count(SHUTDOWN) == 1, "native success and shutdown")
    need(not any("FAILED:" in line for line in lines), "no native failure")
    receipts = [json.loads(line[len(PREFIX):]) for line in lines if line.startswith(PREFIX)]
    need(len(receipts) == 1, "one receipt")
    r = receipts[0]
    need(r.get("schema") == 1 and r.get("notchWidth") == 330, "counterexample identity")
    for key in ("synthetic", "stableDetails", "realExitClosed", "pauseReleasedOrigin"):
        need(r.get(key) is True, key)
    for key in ("globalSystemDelivery", "lyricsSelected"):
        need(r.get(key) is False, key)
    need(r.get("settledHoldSeconds") == 2.4, "bounded stable hold")
    need(type(r.get("polls")) is int and r["polls"] >= 30, "production timer polls")
    need(type(r.get("playbackReads")) is int and r["playbackReads"] >= 3, "playback refreshes")
    need(type(r.get("pointer")) is list and len(r["pointer"]) == 2, "pointer receipt")
    return r


def validate_red(log, returncode):
    # AppController reports semantic smoke failures before an orderly NSApp
    # shutdown, which exits zero. A nonzero exit/crash is NOT expected red.
    # This receipt proves the exact settle failure, not its physical cause.
    lines = log.splitlines()
    need(returncode == 0, "original must terminate normally, not crash")
    failures = [line for line in lines if "FAILED:" in line]
    need(len(failures) == 2 and failures.count(RED_FAILURE) == 1
         and failures.count(RED_SHUTDOWN) == 1,
         "original must report only the exact settle failure and smoke shutdown")
    need(not any(marker in line.lower() for line in lines
                 for marker in ("fatal error", "error:", "deadline exceeded")),
         "original must not contain runtime error or deadline diagnostics")
    need(not any("_OK:" in line or line.startswith(PREFIX) for line in lines),
         "original must not report success or a green receipt")


def self_test():
    r = dict(schema=1, notchWidth=330, synthetic=True, globalSystemDelivery=False,
             lyricsSelected=False, stableDetails=True, realExitClosed=True, pauseReleasedOrigin=True,
             settledHoldSeconds=2.4, polls=70, playbackReads=4, pointer=[914, 884])
    def log(row):
        return PREFIX + json.dumps(row) + "\n" + OK + "\n" + SHUTDOWN
    validate(log(r))
    count = 1
    for key, wrong in (("stableDetails", False), ("realExitClosed", False), ("pauseReleasedOrigin", False),
                       ("globalSystemDelivery", True), ("lyricsSelected", True), ("polls", 0),
                       ("playbackReads", 1), ("notchWidth", 220), ("settledHoldSeconds", 0)):
        bad = copy.deepcopy(r); bad[key] = wrong
        try:
            validate(log(bad))
        except ValueError:
            count += 1
        else:
            raise ValueError("accepted invalid " + key)
    red = RED_FAILURE + "\n" + RED_SHUTDOWN
    validate_red(red, 0)
    count += 1
    invalid_red = [
        ("nonzero", red, 1),
        ("crash", red, -11),
        ("missing failure", RED_SHUTDOWN, 0),
        ("missing shutdown", RED_FAILURE, 0),
        ("empty", "", 0),
        ("wrong failure", red.replace("wide-music-quota-settled", "wide-music-quota-real-exit-closes"), 0),
        ("trailing malformed", red.replace(RED_FAILURE, RED_FAILURE + " extra"), 0),
        ("prefixed malformed", "prefix " + red, 0),
        ("duplicate failure", red + "\n" + RED_FAILURE, 0),
        ("duplicate shutdown", red + "\n" + RED_SHUTDOWN, 0),
        ("unrelated failure", red + "\nOTHER_FAILED: unexpected", 0),
        ("green success", red + "\n" + OK, 0),
        ("successful shutdown", red + "\n" + SHUTDOWN, 0),
        ("unrelated success", red + "\nOTHER_OK: unexpected", 0),
        ("green receipt", red + "\n" + PREFIX + json.dumps(r), 0),
        ("fatal runtime", red + "\nFatal error: unexpectedly found nil", 0),
        ("runtime error", red + "\nERROR: unexpected native diagnostic", 0),
        ("deadline", red + "\nDeadline exceeded during native capture", 0),
    ]
    for name, bad_log, code in invalid_red:
        try:
            validate_red(bad_log, code)
        except ValueError:
            count += 1
        else:
            raise ValueError("accepted invalid red " + name)
    print(f"MUSIC_WIDE_QUOTA_PARSER_SELF_TEST_OK: assertions={count} nativeAppRun=false")


def red_green(binary):
    # Overlay only the harness onto an immutable original commit. Neither the
    # production geometry nor the panel fix may enter the red executable.
    revision = subprocess.check_output(["git", "rev-parse", BASELINE + "^{commit}"], cwd=ROOT, text=True).strip()
    need(revision == BASELINE, "exact original baseline")
    archive = subprocess.check_output(["git", "archive", "--format=tar", BASELINE], cwd=ROOT)
    dist = ROOT / "dist"
    need(not dist.is_symlink(), "refuse symlinked dist")
    dist.mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="wide-quota-red-", dir=dist) as directory:
        stage = Path(directory)
        with tarfile.open(fileobj=io.BytesIO(archive)) as source:
            for entry in source.getmembers():
                path = Path(entry.name)
                need(not path.is_absolute() and ".." not in path.parts and (entry.isfile() or entry.isdir()), "safe baseline path")
                target = stage / path
                if entry.isdir():
                    target.mkdir(parents=True, exist_ok=True)
                else:
                    target.parent.mkdir(parents=True, exist_ok=True)
                    target.write_bytes(source.extractfile(entry).read())
                    target.chmod(entry.mode & 0o777)
        fixture = Path("Sources/CodexNotchMeter/MusicStationaryHoverChecks.swift")
        harness = (ROOT / fixture).read_bytes()
        (stage / fixture).write_bytes(harness)
        subprocess.run(["swift", "build", "--product", "CodexNotchMeter"], cwd=stage, check=True, timeout=300)
        bin_dir = subprocess.check_output(["swift", "build", "--show-bin-path"], cwd=stage, text=True).strip()
        old = subprocess.run([str(Path(bin_dir) / "CodexNotchMeter"), *FLAGS], cwd=ROOT,
                             capture_output=True, text=True, timeout=65)
        red_log = old.stdout + old.stderr
        (dist / "music-wide-quota-red.log").write_text(red_log)
        print(red_log, end="")
        validate_red(red_log, old.returncode)
        (dist / "music-wide-quota-source.json").write_text(json.dumps({
            "baseline": BASELINE, "overlay": str(fixture), "overlaySHA256": hashlib.sha256(harness).hexdigest(),
            "productionOverlay": False}, indent=2))
    run_green(binary)


def run_green(binary):
    result = subprocess.run([str(binary), *FLAGS], cwd=ROOT, capture_output=True, text=True, timeout=65)
    log = result.stdout + result.stderr
    output = ROOT / "dist/music-wide-quota-hover.log"
    output.parent.mkdir(parents=True, exist_ok=True); output.write_text(log)
    print(log, end="")
    need(result.returncode == 0, "native process exit")
    validate(log)


def main():
    if sys.argv[1:] == ["--self-test"]:
        self_test(); return
    if len(sys.argv) == 3 and sys.argv[1] == "--validate-log":
        validate(Path(sys.argv[2]).read_text()); return
    need(len(sys.argv) <= 2, "usage: [APP_BINARY] | --self-test | --red-green | --validate-log LOG")
    red = sys.argv[1:] == ["--red-green"]
    binary = (Path(sys.argv[1]).resolve() if len(sys.argv) == 2 and not red
              else ROOT / "dist/Codex Notch Meter.app/Contents/MacOS/CodexNotchMeter")
    if red:
        red_green(binary)
    else:
        run_green(binary)



if __name__ == "__main__":
    try:
        main()
    except (ValueError, KeyError, TypeError, OSError, subprocess.TimeoutExpired, subprocess.CalledProcessError) as error:
        print("MUSIC_WIDE_QUOTA_HOVER_FAILED: " + str(error), file=sys.stderr)
        sys.exit(1)
