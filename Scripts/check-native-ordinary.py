#!/usr/bin/env python3
"""Independent <=60s ordinary-path native gate; local app only, no screenshots.

C1/shape receipts prove numerical/native submission coherence, not scanout or feel.
"""
from copy import deepcopy
import json
import math
from pathlib import Path
import subprocess
import sys

PREFIX = 'ORDINARY_MOTION_TRACE_JSON: '
OK = 'ORDINARY_MOTION_OK: cases=8 deadline=60 synthetic=true naturalPaint=true scanout=false'
SHUTDOWN = 'SMOKE_OK: native island geometry, expansion and orderly shutdown completed; demo-only'
NAMES = ['ordinary-reentry', 'quota-takeover-replacement-expiry', 'playback-during-opening',
         'playback-close-owner-redirect-pause', 'content-fit-pending', 'reduced-motion',
         'bridge-tail-revision', 'bridge-adjacent-retarget-gap']
EVENTS = [ ['open', 'close', 'closing-intermediate', 'reentry', 'settled'],
           ['open', 'close', 'closing-intermediate', 'quota-takeover', 'quota-replacement', 'quota-expired', 'settled'],
           ['open', 'playing', 'settled', 'paused', 'close', 'settled'],
           ['open', 'close', 'closing-intermediate', 'playing', 'owner-redirect', 'paused', 'quota-expired', 'settled'],
           ['open', 'content-fit-pending', 'close', 'closing-intermediate', 'quota-takeover', 'quota-expired', 'settled', 'content-fit-adopted'],
           ['open', 'close', 'quota-takeover', 'playing', 'quota-dismissed', 'settled'],
           ['open', 'close', 'late-bridge-redirect', 'bridge-only-tail', 'settled'],
           ['open', 'close', 'closing-intermediate', 'bridge-redirect', 'adjacent-gap-reentry', 'settled', 'close', 'settled'] ]

def number(x):
    return isinstance(x, (int, float)) and not isinstance(x, bool) and math.isfinite(x)

def vector(x, n):
    return isinstance(x, list) and len(x) == n and all(number(v) for v in x)

def near(a, b, eps=1e-7):
    return abs(a-b) <= eps

def ordered(rows, key, strict=False):
    return all(number(r[key]) for r in rows) and all(
        b[key] > a[key] if strict else b[key] >= a[key] for a, b in zip(rows, rows[1:]))

def subsequence(actual, required):
    it = iter(actual)
    return all(any(value == wanted for value in it) for wanted in required)

def valid_trace(t):
    try:
        if t['schema'] != 1 or t['overflow'] is not False or t['synthetic'] is not True or t['naturalPaint'] is not True or t['scanout'] is not False:
            return False
        if not number(t['elapsed']) or not 0 < t['elapsed'] <= 60 or [c['name'] for c in t['cases']] != NAMES:
            return False
        for index, c in enumerate(t['cases']):
            reduced = index == 5
            if c['stopped'] is not True or c['readerDrained'] is not True or c['sameFrameBodyClipRail'] is not True:
                return False
            events, commits, paints, callbacks, handoffs, reads = (c[k] for k in ['events', 'commits', 'paints', 'callbacks', 'handoffs', 'reads'])
            if not 1 <= len(events) <= 64 or not 2 <= len(commits) <= 4096 or not 2 <= len(paints) <= 4096 or len(callbacks) > 1000 or len(handoffs) > 32:
                return False
            if not subsequence([e['name'] for e in events], EVENTS[index]) or not ordered(events, 'time'):
                return False
            for e in events:
                if not all(number(e[k]) for k in ['time', 'progress', 'velocity', 'target', 'width', 'center', 'widthVelocity', 'centerVelocity']):
                    return False
                if not 0 <= e['progress'] <= 1 or not 0 <= e['target'] <= 1 or e['profile'] not in ['ordinary-v100', 'ordinary-handoff', 'shared-v103']:
                    return False
            if not ordered(commits, 'revision', True) or not ordered(commits, 'observed') or not ordered(paints, 'sequence', True) or not ordered(paints, 'revision') or not ordered(paints, 'observed'):
                return False
            by_revision = {f['revision']: f for f in commits}
            screen = c['screen']
            if not vector(screen, 4):
                return False
            for f in commits:
                if not vector(f['frame'], 4) or not vector(f['contour'], 4) or not number(f['progress']) or not 0 <= f['progress'] <= 1:
                    return False
                if not all(number(f[k]) for k in ['width', 'center', 'expectedWidth', 'expectedCenter', 'target']):
                    return False
                if not near(f['width'], f['contour'][2]) or not near(f['center'], f['frame'][0]+f['contour'][0]+f['width']/2):
                    return False
                if f['width'] <= 0 or f['center']-f['width']/2 < screen[0]-1e-6 or f['center']+f['width']/2 > screen[0]+screen[2]+1e-6:
                    return False
                if f['ordinary'] and (not near(f['width'], f['expectedWidth']) or not near(f['center'], f['expectedCenter'])):
                    return False
            for p in paints:
                f = by_revision[p['revision']]
                if p['sampledAtPaint'] is not True or p['observed'] < f['observed'] or p['progress'] != f['progress'] or p['frame'] != f['frame'] or p['contour'] != f['contour']:
                    return False
                if p['viewport'] != f['frame'][2:] or p['content'] != [0, 0] + f['frame'][2:]:
                    return False
                if not vector(p['bodyBounds'], 4) or p['bodyBounds'] != p['clipBounds'] or not vector(p['railBounds'], 4) or p['railBounds'] != p['expectedRailBounds']:
                    return False
            moving = {f['revision'] for f in commits if 0 < f['progress'] < 1}
            painted = {p['revision'] for p in paints}
            if not reduced and (len(callbacks) < 4 or len(moving & painted) < 2):
                return False
            for b in callbacks:
                if index in [6,7] and b['source'] != 'dispatch-60hz': return False
                if not vector(b['widthSample'], 4) or not vector(b['frame'], 4) or not all(number(b[k]) for k in ['progress', 'velocity', 'observed', 'scheduled', 'bridgeElapsed']):
                    return False
                if b['profile'] == 'ordinary-handoff':
                    if not 0 <= b['bridgeElapsed'] <= 0.23000001 or not vector(b['bridgeTarget'], 4):
                        return False
                    if b['bridgeElapsed'] >= 0.23 and any(not near(a, z) for a, z in zip(b['widthSample'], b['bridgeTarget'])):
                        return False
                elif b['bridgeElapsed'] != -1 or b['bridgeTarget'] != []:
                    return False
            if [h['sequence'] for h in handoffs] != list(range(1, len(handoffs)+1)):
                return False
            for h in handoffs:
                if not vector(h['before'], 4) or not vector(h['after'], 4) or not vector(h['target'], 4) or h['before'] != h['after']:
                    return False
                if not number(h['eventTime']) or not number(h['integratedTime']) or h['integratedTime'] < h['eventTime'] or h['integratedTime'] - h['eventTime'] > .1:
                    return False
                if h['target'][2:] != [0, 0] or h['oldProfile'] not in ['ordinary-v100', 'ordinary-handoff']:
                    return False
            if index in [0, 2] and handoffs:
                return False
            if index in [1, 4] and not handoffs or index == 3 and len(handoffs) < 2:
                return False
            if index in [6, 7] and len(handoffs) < 2:
                return False
            if index in [1, 3, 4] and (handoffs[0]['before'][2] >= -1 or handoffs[0]['oldProfile'] != 'ordinary-v100'):
                return False
            if index == 0 and not any(e['name'] == 'reentry' and e['profile'] == 'ordinary-v100' and 0 < e['progress'] < 1 for e in events):
                return False
            if index == 2 and not any(e['name'] == 'playing' and e['profile'] == 'ordinary-v100' and 0 < e['progress'] < 1 for e in events):
                return False
            if index == 3 and not any(e['name'] == 'playing' and e['profile'] == 'ordinary-handoff' and 0 < e['progress'] < 1 for e in events):
                return False
            close = c['close']
            if index != 5:
                if close['outcome'] != 'ready' or not all(number(close[k]) for k in ['requested', 'rendered', 'painted', 'completed']):
                    return False
                if not close['requested'] <= min(close['rendered'], close['painted']) <= max(close['rendered'], close['painted']) <= close['completed']:
                    return False
            notices = c['noticeRecords']
            requests = [n for n in notices if n['kind'] == 'requested']
            expires = [n for n in notices if n['kind'] == 'expired']
            if len({n['id'] for n in requests}) != len(requests):
                return False
            if index in [1, 3, 4]:
                if len(expires) != 1 or not requests or (index == 1 and len(requests) != 2):
                    return False
                n, request = expires[0], requests[-1]
                if n['id'] != request['id'] or n['requested'] != request['requested'] or n['hold'] != request['hold']:
                    return False
                if not all(number(n[k]) for k in ['requested', 'painted', 'armed', 'expired', 'hold']) or n['hold'] != 2:
                    return False
                if not n['requested'] <= n['painted'] <= n['armed'] or not n['armed'] + n['hold'] <= n['expired'] <= n['armed'] + n['hold'] + .15:
                    return False
                if not any(p['noticeID'] == n['id'] and p['observed'] == n['painted'] for p in paints):
                    return False
                expiry_events = [e for e in events if e['name'] == 'quota-expired']
                if len(expiry_events) != 1 or not n['expired'] <= expiry_events[0]['time'] <= n['expired']+.1:
                    return False
            if index == 6:
                pairs = [(a,b) for a,b in zip(callbacks, callbacks[1:]) if a['profile'] == 'ordinary-handoff'
                         and b['profile'] == 'shared-v103' and a['progress'] == b['progress'] == 0
                         and all(a[k] == b[k] for k in ['frame', 'accessory', 'noticeID', 'musicRevision'])
                         and b['revision'] > a['revision']]
                if not pairs or all(h['before'] == h['target'] for h in handoffs):
                    return False
                a,b = pairs[-1]
                if not b['observed'] <= close['requested'] <= b['observed'] + .1:
                    return False
                if not any(p['revision'] == b['revision'] and p['observed'] >= close['requested'] for p in paints):
                    return False
            gaps = c['gapRecords']
            if index == 7:
                if len(gaps) != 1: return False
                g = gaps[0]
                if not vector(g['outside'],2) or not vector(g['inside'],2) or not .09 <= math.dist(g['outside'],g['inside']) <= .11:
                    return False
                if g['expected'] is not True or g['actual'] is not True or g['mismatched'] is not False or g['updatePointerCalls'] != 3:
                    return False
                if not all(number(g[k]) for k in ['published','integrated','outsideAt','reentryAt']) or g['published'] == g['integrated'] or not 0 < g['reentryAt']-g['outsideAt'] < .1:
                    return False
            elif gaps:
                return False
            if index != 5 and (events[-1]['progress'] != 0 or events[-1]['profile'] != 'shared-v103'):
                return False
            if c['readsReturned'] != len(reads) or [r['id'] for r in reads] != list(range(1, len(reads)+1)):
                return False
            for r in reads:
                if r['prompt'] is not False or r['state'] not in ['playing', 'paused', 'cancelled'] or not all(number(r[k]) for k in ['started', 'released', 'returned']) or not r['started'] <= r['released'] <= r['returned']:
                    return False
            for state in ['playing', 'paused']:
                es = [e for e in events if e['name'] == state]
                rs = [r for r in reads if r['state'] == state]
                if len(es) != len(rs) or any(e['time'] < r['returned'] or e['time'] - r['returned'] > 1 for e, r in zip(es, rs)):
                    return False
        return True
    except (KeyError, TypeError, ValueError, IndexError, OverflowError):
        return False

def valid(output):
    if len(output) > 3_000_000 or 'FAILED' in output or 'ORDINARY_MOTION_ERROR:' in output:
        return False
    lines = output.splitlines()
    traces = [line[len(PREFIX):] for line in lines if line.startswith(PREFIX)]
    if len(traces) != 1 or lines.count(OK) != 1 or lines.count(SHUTDOWN) != 1:
        return False
    if not lines.index(PREFIX + traces[0]) < lines.index(OK) < lines.index(SHUTDOWN):
        return False
    try:
        return valid_trace(json.loads(traces[0], parse_constant=lambda _: (_ for _ in ()).throw(ValueError())))
    except (ValueError, TypeError):
        return False

def fixture():
    cases = []
    for index, name in enumerate(NAMES):
        es = []
        for i, event in enumerate(EVENTS[index]):
            progress = 0 if i == len(EVENTS[index])-1 else .5
            profile = 'shared-v103'
            if event == 'reentry' or index == 2 and event == 'playing': profile = 'ordinary-v100'
            if index == 3 and event == 'playing': profile = 'ordinary-handoff'
            es.append(dict(name=event, time=10+i, progress=progress, velocity=0, target=0, width=220, center=500,
                           widthVelocity=0, centerVelocity=0, profile=profile, owner='idle'))
        fs = [dict(revision=i+1, observed=1+i*.1, progress=.2+i*.1, frame=[390, 800, 220, 100],
                   contour=[0, 0, 220, 100], ordinary=True, width=220, center=500, expectedWidth=220,
                   expectedCenter=500, owner='details', target=1) for i in range(4)]
        ps = [dict(sequence=i+1, revision=f['revision'], observed=f['observed']+.01, progress=f['progress'],
                   frame=f['frame'][:], contour=f['contour'][:], viewport=[220, 100], content=[0, 0, 220, 100], sampledAtPaint=True, bodyBounds=[0,0,220,100], clipBounds=[0,0,220,100],
                   railBounds=[2,2,216,98], expectedRailBounds=[2,2,216,98], accessory=0, noticeID='', musicRevision=0) for i, f in enumerate(fs)]
        bs = [dict(observed=1+i*.1, scheduled=1+i*.1, progress=.5, velocity=1, frame=[390,800,220,100],
                   profile='ordinary-v100', source='dispatch-60hz', widthSample=[220,500,0,0], bridgeElapsed=-1, bridgeTarget=[],
                   revision=i+1, accessory=0, noticeID='', musicRevision=0, renderedAt=1) for i in range(4)]
        hs = [dict(sequence=i+1, eventTime=2+i, integratedTime=2+i, before=[220,500,-15,0], after=[220,500,-15,0],
                   target=[300,500,0,0], oldProfile='ordinary-v100' if i==0 else 'ordinary-handoff', owner='quotaNotice')
              for i in range(1 if index in [1, 4] else 2 if index in [3,6,7] else 0)]
        rs = [dict(id=j+1, started=e['time']-.3, released=e['time']-.2, returned=e['time']-.1, state=e['name'], prompt=False)
              for j, e in enumerate(e for e in es if e['name'] in ['playing', 'paused'])]
        notices = []
        if index in [1,3,4]:
            expired = next(e['time'] for e in es if e['name'] == 'quota-expired')-.01
            requested, painted, armed = expired-2.3, expired-2.2, expired-2.1
            if index == 1: notices.append(dict(kind='requested',id='old',requested=requested-.04,hold=2))
            notices.extend([dict(kind='requested',id='new',requested=requested,hold=2),
                            dict(kind='expired',id='new',requested=requested,hold=2,painted=painted,armed=armed,expired=expired)])
            for j,(f,p) in enumerate(zip(fs,ps)):
                f['observed']=painted-.11+j*.1
                p['observed']=f['observed']+.01
            ps[1]['observed']=painted
            ps[1]['noticeID']='new'
        close = dict(requested=1.301,rendered=1.32,painted=1.31,completed=1.34,outcome='ready')
        gaps = []
        if index == 6:
            for row in fs[-2:]+ps[-2:]+bs[-2:]: row['progress']=0
            bs[-2].update(profile='ordinary-handoff',bridgeElapsed=.22,bridgeTarget=[220,500,0,0])
            bs[-1].update(profile='shared-v103')
        if index == 7:
            gaps=[dict(outside=[610.05,850],inside=[609.95,850],outsideAt=11,reentryAt=11.004,
                       published=.15,integrated=.14,expected=True,mismatched=False,actual=True,updatePointerCalls=3)]
        cases.append(dict(name=name, close=close, noticeRecords=notices,gapRecords=gaps,events=es, commits=fs, paints=ps, callbacks=bs, handoffs=hs, reads=rs,
                          readsReturned=len(rs), screen=[0,0,1000,900], stopped=True, readerDrained=True, sameFrameBodyClipRail=True))
    return dict(schema=1, cases=cases, elapsed=25, overflow=False, synthetic=True, naturalPaint=True, scanout=False)

def encode(t):
    return PREFIX + json.dumps(t, separators=(',', ':')) + '\n' + OK + '\n' + SHUTDOWN + '\n'

def self_test():
    original = fixture()
    assert valid(encode(original)), 'valid protocol fixture rejected'
    mutations = [
        lambda t: t.update(overflow=True), lambda t: t.update(elapsed=61),
        lambda t: t['cases'].pop(), lambda t: t['cases'][0].update(readerDrained=False),
        lambda t: t['cases'][0]['paints'][0].update(sampledAtPaint=False),
        lambda t: t['cases'][0]['paints'][0].update(revision=999),
        lambda t: t['cases'][0]['paints'][0]['frame'].__setitem__(2, 221),
        lambda t: t['cases'][0]['commits'][0].update(expectedWidth=221),
        lambda t: t['cases'][0]['commits'][0].update(width=float('nan')),
        lambda t: t['cases'][1]['handoffs'][0]['after'].__setitem__(2, 0),
        lambda t: t['cases'][1]['handoffs'][0].update(integratedTime=0),
        lambda t: t['cases'][3]['handoffs'].pop(),
        lambda t: t['cases'][1]['handoffs'][0].update(before=[220,500,0,0], after=[220,500,0,0]),
        lambda t: t['cases'][0].update(stopped=False),
        lambda t: t['cases'][0]['events'][-1].update(progress=.001),
        lambda t: t['cases'][2]['events'][1].update(profile='shared-v103'),
        lambda t: t['cases'][2]['reads'][0].update(returned=999),
        lambda t: t['cases'][2]['reads'][0].update(prompt=True),
        lambda t: t['cases'][0].update(callbacks=[]),
        lambda t: t['cases'][0]['events'].pop(),
        lambda t: t['cases'][0]['callbacks'][0].update(profile='ordinary-handoff', bridgeElapsed=.3),
        lambda t: t['cases'][0]['close'].update(outcome='timedOut'),
        lambda t: t['cases'][0]['close'].update(rendered=0),
        lambda t: t['cases'][1]['noticeRecords'][-1].update(id='old'),
        lambda t: t['cases'][1]['noticeRecords'][-1].update(expired=0),
        lambda t: t['cases'][1]['paints'][1].update(noticeID='old'),
        lambda t: t['cases'][6]['callbacks'][-1].update(revision=3),
        lambda t: t['cases'][6]['callbacks'][-1].update(accessory=1),
        lambda t: t['cases'][7]['gapRecords'][0].update(actual=False),
        lambda t: t['cases'][7]['callbacks'][0].update(source='view-display-link'),
        lambda t: t['cases'][7]['gapRecords'][0].update(outside=[-100,850]),
        lambda t: t['cases'][0]['paints'][0]['clipBounds'].__setitem__(2,219),
    ]
    for mutate in mutations:
        value = deepcopy(original); mutate(value)
        assert not valid(encode(value)), 'negative control incorrectly accepted'
    output = encode(original)
    for bad in [output.replace(SHUTDOWN, ''), SHUTDOWN+'\n'+output.replace(SHUTDOWN, ''), output+SHUTDOWN+'\n', output+OK+'\n', output+'ORDINARY_MOTION_FAILED:\n', output+PREFIX+'{}\n']:
        assert not valid(bad), 'shutdown/duplicate negative incorrectly accepted'
    print(f'ORDINARY_RUNNER_SELFTEST_OK: positive=1 negative={len(mutations)+6}')

def main():
    self_test()
    if sys.argv[1:] == ['--self-test']: return
    if sys.argv[1:]: raise SystemExit('Usage: check-native-ordinary.py [--self-test]')
    binary = Path(__file__).resolve().parents[1] / 'dist/Codex Notch Meter.app/Contents/MacOS/CodexNotchMeter'
    process = subprocess.Popen([str(binary), '--music-test', '--ordinary-motion-test', '--motion-test'], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    try:
        stdout, stderr = process.communicate(timeout=65)
    except subprocess.TimeoutExpired:
        process.kill(); stdout, stderr = process.communicate(timeout=5)
        print(stdout); print(stderr)
        raise SystemExit('Ordinary native gate exceeded 60-second watchdog plus 5-second shutdown allowance')
    print(stdout); print(stderr)
    if process.returncode != 0 or not valid(stdout) or 'ORDINARY_MOTION_FAILED:' in stderr:
        raise SystemExit('Ordinary native evidence or actual orderly shutdown failed')

if __name__ == '__main__': main()
