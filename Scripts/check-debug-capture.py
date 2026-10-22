#!/usr/bin/env python3
"""Strict offline JSONL/privacy parser and optional independent macOS fixture.
Parser/source checks are not Swift compilation or real-user UI validation.
"""
import argparse
from copy import deepcopy
import json
import math
import re
from pathlib import Path
import subprocess
import sys

FIELDS = set('''island deliveredOffsetMs decisionOffsetMs sourceOffsetMs sourceAgeMs scheduledOffsetMs elapsedMs applyMs
progress target velocity accessory accessoryTarget widthBridge width height centerOffset topError screenWidth screenHeight scale
notchWidth notchHeight horizontalAdjustment widthAdjustment depthAdjustment cornerAdjustment pointerX pointerY anchorX anchorY
inside expandedBefore expandedAfter reserved gestureGate corridorExitRequired fresh playing lyricsMode enabled presentationRevision
playbackRevision noticeRevision frameRevision settings menu popover allowed quotaError quotaStale reducedMotion frameGapMs eventGapMs pollGapMs rawPollGapMs readMs'''.split())
EVENTS = set('geometry pollTick inputIngress pollIngress input hover ownership frame frameCallback width music gate lifecycle'.split())
LABELS = set('source owner previousOwner reason outcome readPhase readFailure lookup'.split())
VALUES = set('''idle music quotaNotice details localEvent globalEvent poll synthetic displayLink dispatchTimer timer unknown snapshot accepted
staleEvent duplicateEvent quietWindow invalid button noticeOwns gestureAccepted gestureUnavailable reserved gestureGate dwellReset hoverDecision
enter leave retarget accessoryChanged bridgeChanged geometryChanged musicChanged gateChanged noticeShown noticeDismissed noticeExpired collapse stopped
ready timedOut target permission stateBefore trackBefore position trackAfter stateAfter validation none notRunning denied timeout malformed changedTrack
unavailable failed loading matched noMatch invalidMetadata identityMismatch rateLimited serviceUnavailable temporaryFailure rejected
searchResultsTruncated waitingForProvider'''.split())
COUNTERS = set('''localEvents globalEvents pollCallbacks polls acceptedPolls quietPolls rejectedEvents hoverDecisions frameCallbacks frameApplies
sampledOut rateLimited evicted oversized invalidFields identifierOverflow encodingFailures'''.split())
ROW_KEYS = {'sequence', 'elapsedMs', 'event', 'values', 'labels'}
HEADER_KEYS = {'schema', 'kind', 'session', 'version', 'build', 'durationLimitSeconds', 'byteLimit', 'timing', 'latestGeometryContext'}
SUMMARY_KEYS = {'kind', 'elapsedMs', 'stopReason', 'retainedEvents', 'recordWorkMs', 'maximumRecordWorkMs', 'measuredRecords', 'counters'}
TIMING = 'elapsedMs=actual monotonic observation; sourceOffsetMs=event uptime; scheduledOffsetMs=frame scheduler clock, all relative to capture start, not wall time'

def require(value, message):
    if not value:
        raise ValueError(message)

def finite(value):
    return type(value) in (int, float) and math.isfinite(value)

def positive_int(value):
    return type(value) is int and value >= 0

def object_pairs(pairs):
    result = {}
    for key, value in pairs:
        require(key not in result, 'duplicate JSON key')
        result[key] = value
    return result

def check_row(row):
    require(type(row) is dict and set(row) == ROW_KEYS, 'row keys')
    require(positive_int(row['sequence']) and row['sequence'] > 0, 'sequence')
    require(finite(row['elapsedMs']) and row['elapsedMs'] >= 0, 'observation clock')
    require(row['event'] in EVENTS, 'event allowlist')
    require(type(row['values']) is dict and set(row['values']) <= FIELDS, 'numeric field allowlist')
    require(all(finite(v) and abs(v) <= 10_000_000 for v in row['values'].values()), 'numeric bounds')
    for key in ('pointerX', 'pointerY', 'anchorX', 'anchorY'):
        require(key not in row['values'] or abs(row['values'][key]) <= 1024, 'pointer bounds')
    require(type(row['labels']) is dict and set(row['labels']) <= LABELS, 'label allowlist')
    require(all(v in VALUES for v in row['labels'].values()), 'text value allowlist')

def validate(data):
    require(len(data) <= 2 * 1024 * 1024 and data.endswith(b'\n'), 'size/newline')
    rows = [json.loads(line, object_pairs_hook=object_pairs) for line in data.splitlines()]
    require(len(rows) >= 2, 'header and summary')
    header, summary, events = rows[0], rows[-1], rows[1:-1]
    require(set(header) == HEADER_KEYS and header['schema'] == 'codex-notch-debug/1' and header['kind'] == 'schema', 'schema')
    import uuid
    uuid.UUID(header['session'])
    for key in ('version', 'build'):
        value = header[key]
        require(type(value) is str and (value == 'unknown' or (0 < len(value) <= 32 and set(value) <= set('0123456789.'))), 'metadata allowlist')
    require(finite(header['durationLimitSeconds']) and 0 < header['durationLimitSeconds'] <= 300, 'duration bound')
    require(positive_int(header['byteLimit']) and len(data) <= header['byteLimit'] <= 2 * 1024 * 1024, 'export byte bound')
    require(header['timing'] == TIMING, 'clock explanation')
    context = header['latestGeometryContext']
    require(type(context) is list and len(context) <= 8, 'bounded geometry context')
    context_fields = set('island screenWidth screenHeight scale notchWidth notchHeight horizontalAdjustment widthAdjustment depthAdjustment cornerAdjustment reducedMotion'.split())
    for row in context:
        check_row(row)
        require(row['event'] == 'geometry' and set(row['values']) == context_fields and row['labels'] == {}, 'safe geometry context')
    require(set(summary) == SUMMARY_KEYS and summary['kind'] == 'summary', 'summary keys')
    require(summary['stopReason'] in ('manual', 'durationLimit', 'applicationExit'), 'explicit stop')
    require(positive_int(summary['retainedEvents']) and summary['retainedEvents'] == len(events) <= 4096, 'retained count')
    require(type(summary['counters']) is dict and set(summary['counters']) <= COUNTERS and all(positive_int(v) for v in summary['counters'].values()), 'bounded counters')
    require(all(finite(summary[k]) and summary[k] >= 0 for k in ('elapsedMs', 'recordWorkMs', 'maximumRecordWorkMs')), 'summary metrics')
    require(positive_int(summary['measuredRecords']), 'work count')
    previous_sequence, previous_time = 0, 0
    for row in events:
        check_row(row)
        require(row['sequence'] > previous_sequence and row['elapsedMs'] >= previous_time, 'monotonic order')
        previous_sequence, previous_time = row['sequence'], row['elapsedMs']
    require(summary['elapsedMs'] >= previous_time, 'stop after retained observations')
    return rows

def encode(rows):
    return ('\n'.join(json.dumps(row, sort_keys=True) for row in rows) + '\n').encode()

def self_test():
    rows = [dict(schema='codex-notch-debug/1', kind='schema', session='00000000-0000-4000-8000-000000000001', version='1.1.3', build='14', durationLimitSeconds=300, byteLimit=2097152, timing=TIMING, latestGeometryContext=[]),
            dict(sequence=1, elapsedMs=100, event='hover', values=dict(island=1, sourceOffsetMs=20, decisionOffsetMs=90, pointerX=4), labels=dict(owner='details', reason='enter')),
            dict(kind='summary', elapsedMs=110, stopReason='manual', retainedEvents=1, recordWorkMs=.1, maximumRecordWorkMs=.1, measuredRecords=1, counters=dict(polls=1))]
    validate(encode(rows)); rejected = 0
    mutations = [lambda r: r[1].update(title='PRIVATE_TITLE'), lambda r: r[1]['values'].update(token=1),
        lambda r: r[1]['labels'].update(reason='PRIVATE_LYRICS'), lambda r: r[1]['values'].update(pointerX=50000),
        lambda r: r[1]['values'].update(progress=float('nan')), lambda r: r[0].update(version='PRIVATE_TOKEN'),
        lambda r: r[-1].update(retainedEvents=2), lambda r: r[1].update(elapsedMs=-1),
        lambda r: r[-1].update(stopReason='upload'), lambda r: r[0].update(latestGeometryContext=[r[1]]),
        lambda r: r[1]['values'].update(filePath='/private/example')]
    for mutate in mutations:
        changed = deepcopy(rows); mutate(changed)
        try: validate(encode(changed))
        except (ValueError, TypeError): rejected += 1
        else: raise AssertionError('unsafe mutation accepted')
    root = Path(__file__).resolve().parent.parent
    core = (root / 'Sources/NotchCore/DebugCapture.swift').read_text()
    panel = (root / 'Sources/CodexNotchMeter/IslandPanel.swift').read_text()
    ui = (root / 'Sources/CodexNotchMeter/DebugCaptureController.swift').read_text()
    for forbidden in ('URLSession', 'URLRequest', 'UserDefaults', 'FileHandle', 'print('):
        require(forbidden not in core and forbidden not in ui, 'no automatic output/network/persistence')
    for required in ('sourceOffsetMs', 'deliveredOffsetMs', 'decisionOffsetMs', 'rawPollGapMs', 'debugState(.ownership', 'debugState(.hover', 'count(.frameCallbacks)'):
        require(required in panel, 'production instrumentation: ' + required)
    for required in ('guard sender === deadline', 'save.runModal() == .OK', 'recorder.export', 'deadline?.invalidate()'):
        require(required in ui, 'lifecycle/export: ' + required)
    native_rejected = native_self_test(rows)
    print(json.dumps({'parser': 'PASS', 'unsafe_mutations_rejected': rejected, 'native_receipt_mutations_rejected': native_rejected, 'static_wiring': 'PASS', 'native_execution': 'NOT_RUN'}))

SUCCESS = 'DEBUG_CAPTURE_OK: realController=true syntheticInput=true physicalJitterVerified=false'
SHUTDOWN = 'SMOKE_OK: native island geometry, expansion and orderly shutdown completed; demo-only'
RECEIPT_KEYS = {'schema', 'realController', 'syntheticInput', 'physicalJitterVerified', 'ownerSequence', 'privacyAllowlist', 'stoppedInert', 'inputExpirySynchronized', 'idleDeadlineStopped', 'noMusicCapture', 'restartClearsSession', 'exportBytes'}

def validate_native(stdout, stderr, returncode):
    lines = stdout.splitlines()
    require(returncode == 0, 'native exit code')
    require(lines.count(SUCCESS) == 1 and lines.count(SHUTDOWN) == 1, 'unique exact native success/shutdown')
    require(sum(line.startswith('DEBUG_CAPTURE_OK:') for line in lines) == 1 and sum(line.startswith('SMOKE_OK:') for line in lines) == 1, 'no ambiguous success')
    require(not re.search(r'(?i)(?:[A-Z_]+_FAILED:|fatal error:|assertion failed:|segmentation fault|uncaught exception|crash report|\berror:)', stdout + '\n' + stderr), 'failure/crash marker')
    receipts = [line[len('DEBUG_CAPTURE_JSON: '):] for line in lines if line.startswith('DEBUG_CAPTURE_JSON: ')]
    require(len(receipts) == 1, 'unique structured receipt')
    receipt = json.loads(receipts[0], object_pairs_hook=object_pairs)
    require(type(receipt) is dict and set(receipt) == RECEIPT_KEYS and type(receipt['schema']) is int and receipt['schema'] == 1, 'receipt schema')
    for key in ('realController', 'syntheticInput', 'privacyAllowlist', 'stoppedInert', 'inputExpirySynchronized', 'idleDeadlineStopped', 'noMusicCapture', 'restartClearsSession'):
        require(receipt[key] is True, 'receipt truth: ' + key)
    require(receipt['physicalJitterVerified'] is False, 'fixture scope')
    captured = [line[len('DEBUG_CAPTURE_ROW: '):] for line in lines if line.startswith('DEBUG_CAPTURE_ROW: ')]
    data = ('\n'.join(captured) + '\n').encode()
    rows = validate(data)
    require(positive_int(receipt['exportBytes']) and receipt['exportBytes'] == len(data), 'exact exported bytes')
    owners = [row['labels'].get('owner') for row in rows[1:-1] if row['event'] == 'ownership']
    require(receipt['ownerSequence'] == owners and owners.count('details') == 2 and owners.count('music') >= 3, 'real controller owner sequence')
    return rows

def native_self_test(rows):
    rows = deepcopy(rows)
    owners = ['music', 'details', 'music', 'details', 'music']
    rows[1:-1] = [dict(sequence=i+1, elapsedMs=i, event='ownership', values=dict(island=1), labels=dict(owner=owner)) for i, owner in enumerate(owners)]
    rows[-1]['retainedEvents'] = len(owners)
    data = encode(rows)
    receipt = dict(schema=1, realController=True, syntheticInput=True, physicalJitterVerified=False, ownerSequence=owners, privacyAllowlist=True, stoppedInert=True, inputExpirySynchronized=True, idleDeadlineStopped=True, noMusicCapture=True, restartClearsSession=True, exportBytes=len(data))
    output = '\n'.join('DEBUG_CAPTURE_ROW: ' + line for line in data.decode().splitlines()) + '\nDEBUG_CAPTURE_JSON: ' + json.dumps(receipt) + '\n' + SUCCESS + '\n' + SHUTDOWN + '\n'
    validate_native(output, '', 0)
    bad = [(output + SUCCESS + '\n', '', 0), (output + 'DEBUG_CAPTURE_FAILED: fixture\n', '', 0),
           (output, 'fatal error: crash', 0), (output, '', 1), (output.replace(SUCCESS, SUCCESS + ' extra'), '', 0),
           (output.replace('"inputExpirySynchronized": true', '"inputExpirySynchronized": false'), '', 0),
           (output.replace('DEBUG_CAPTURE_JSON: ', 'MISSING_RECEIPT: '), '', 0),
           (output.replace('"privacyAllowlist": true', '"privacyAllowlist": 1'), '', 0)]
    for stdout, stderr, code in bad:
        try: validate_native(stdout, stderr, code)
        except ValueError: pass
        else: raise AssertionError('unsafe native result accepted')
    return len(bad)

def native(app):
    result = subprocess.run([app, '--music-test', '--debug-capture-test'], capture_output=True, text=True, timeout=25)
    print(result.stdout, end=''); print(result.stderr, end='', file=sys.stderr)
    validate_native(result.stdout, result.stderr, result.returncode)
    print('Native debug-capture instrumentation fixture PASS; physical jitter and Save UI NOT VERIFIED.')

if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--self-test', action='store_true'); parser.add_argument('--app'); parser.add_argument('--file')
    args = parser.parse_args()
    if args.self_test: self_test()
    if args.file: validate(Path(args.file).read_bytes()); print('Diagnostic schema/privacy allowlist PASS.')
    if args.app: native(args.app)
    if not any((args.self_test, args.app, args.file)): parser.error('choose --self-test, --app or --file')
