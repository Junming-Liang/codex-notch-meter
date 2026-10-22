#!/usr/bin/env python3
"""Explicit old/new own-window width evidence; default is parser self-test only."""
import copy
import hashlib
import importlib.util
import io
import json
import math
from pathlib import Path
import subprocess
import sys
import tarfile
import tempfile

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parent.parent
BASE = '2ef6b1a3ead68e4e67a4f39eaa0d3ff4d8ee2804'
FIXTURE = 'Sources/CodexNotchMeter/MusicStationaryHoverChecks.swift'
FLAGS = ['--music-test', '--music-cache-test', '--music-stationary-hover-test', '--music-details-width-test']
CASE = 'MUSIC_DETAILS_WIDTH_CASE_JSON: '
SUMMARY = 'MUSIC_DETAILS_WIDTH_JSON: '
OK = 'MUSIC_DETAILS_WIDTH_OK: nativeLocal=true naturalPaint=true synthetic=true'
SHUTDOWN = 'SMOKE_OK: native island geometry, expansion and orderly shutdown completed; demo-only'
FAIL = 'MUSIC_STATIONARY_HOVER_FAILED: music-details-visible-side-reversal'
FAILED_SHUTDOWN = 'SMOKE_FAILED: native island checks failed'
EXPECTED = [(w, l, o) for w in (220, 330) for l in (False, True) for o in (True, False)]


def need(value, label):
    if not value:
        raise ValueError(label)


def number(value):
    return type(value) in (int, float) and math.isfinite(value)


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        need(key not in result, 'duplicate JSON key')
        result[key] = value
    return result


def decode(line, prefix):
    value = json.loads(line[len(prefix):], object_pairs_hook=unique_object)
    need(type(value) is dict, 'receipt object')
    return value


def case_check(r):
    need(type(r.get('notchWidth')) in (int, float) and r['notchWidth'] in (220, 330), 'width identity')
    need(type(r.get('lyricsSelected')) is bool and type(r.get('opening')) is bool, 'boolean identity')
    for key in ('ordered', 'allPaintsMatched'):
        need(r.get(key) is True, key)
    need(type(r.get('sidesMonotonic')) is bool, 'monotonic boolean')
    rest, target = r.get('restProgress'), r.get('target')
    need(number(rest) and 0 <= rest < 1 and (rest > 0) == r['lyricsSelected'], 'rest identity')
    need(number(target) and target == (1 if r['opening'] else rest), 'endpoint target')
    cs = r.get('commits')
    need(type(cs) is list and 5 <= len(cs) <= 4096, 'bounded complete commit list')
    for c in cs:
        need(type(c) is dict and type(c.get('revision')) is int and c['revision'] >= 0, 'revision')
        need(all(number(c.get(k)) for k in ('observed', 'progress', 'left', 'right', 'rawWidth')), 'finite geometry')
        need(rest <= c['progress'] <= 1 and c['rawWidth'] > 0 and c['right'] > c['left'], 'geometry range')
        need(abs((c['right'] - c['left']) - (c['rawWidth'] - 24 * c['progress'])) < 1e-6, 'visible side/raw width coherence')
    need(cs[0]['progress'] == (rest if r['opening'] else 1) and cs[-1]['progress'] == target, 'full interval endpoints')
    for a, b in zip(cs, cs[1:]):
        need(b['revision'] > a['revision'] and b['observed'] >= a['observed'], 'ordered revisions and clock')
        need((b['progress'] - a['progress']) * (1 if r['opening'] else -1) >= 0, 'progress direction')
    middle = sum(rest < c['progress'] < 1 for c in cs)
    need(type(r.get('intermediateCommits')) is int and r['intermediateCommits'] == middle and middle >= 3, 'middle commit count')
    need(type(r.get('intermediatePaints')) is int and 2 <= r['intermediatePaints'] <= middle, 'middle paint count')
    monotonic = True
    for side in ('left', 'right'):
        span = cs[-1][side] - cs[0][side]
        for a, b in zip(cs, cs[1:]):
            change = b[side] - a[side]
            monotonic &= abs(change) < 1e-8 if abs(span) < 1e-8 else change * span >= -1e-8
    need(r['sidesMonotonic'] == monotonic, 'independently recomputed side direction')
    return (r['notchWidth'], r['lyricsSelected'], r['opening']), monotonic


def validate(log, code=0, red=False, stderr=""):
    need(not any(x in stderr for x in ("MUSIC_DETAILS_WIDTH_CASE_JSON", "MUSIC_DETAILS_WIDTH_JSON", "_OK:", "FAILED:")), "stderr must not supply receipts or outcome ordering")
    need(not any(x in stderr.lower() for x in ("fatal error", "error:", "deadline exceeded", "exception")), "stderr runtime error")
    need(code == 0, 'normal native exit required')
    need(not any(x in log.lower() for x in ('fatal error', 'error:', 'deadline exceeded', 'exception')), 'runtime error')
    lines = log.splitlines()
    for line in lines:
        for prefix in (CASE, SUMMARY):
            if prefix.rstrip(': ') in line:
                need(line.startswith(prefix), 'malformed or prefixed receipt')
    rows = [decode(x, CASE) for x in lines if x.startswith(CASE)]
    checks = [case_check(r) for r in rows]
    keys = [k for k, _ in checks]
    need(len(keys) == len(set(keys)), 'unique cases')
    failures = [x for x in lines if 'FAILED:' in x]
    successes = [x for x in lines if '_OK:' in x]
    summaries = [decode(x, SUMMARY) for x in lines if x.startswith(SUMMARY)]
    if red:
        need(failures == [FAIL, FAILED_SHUTDOWN] and not successes and not summaries, 'only exact expected old failure')
        need(1 <= len(rows) <= 8 and keys == EXPECTED[:len(rows)], 'old complete ordered case prefix')
        need(all(m for _, m in checks[:-1]) and checks[-1][1] is False, 'actual last-case native reversal')
        need(lines.index(FAIL) > max(i for i, x in enumerate(lines) if x.startswith(CASE)), 'evidence before old failure')
    else:
        need(not failures and successes == [OK, SHUTDOWN], 'unique green success and shutdown')
        need(keys == EXPECTED and all(m for _, m in checks), 'all eight monotonic segments')
        need(len(summaries) == 1 and type(summaries[0].get('schema')) is int and type(summaries[0].get('cases')) is int, 'strict integer summary identity')
        need(all(type(summaries[0].get(k)) is bool for k in ('naturalPaint','nativeLocalEvents','scanout')), 'strict summary booleans')
        need(len(summaries) == 1 and summaries[0] == dict(schema=1, cases=8, naturalPaint=True, nativeLocalEvents=True, scanout=False), 'exact green summary')
        last_case = max(i for i, x in enumerate(lines) if x.startswith(CASE))
        summary_index = next(i for i, x in enumerate(lines) if x.startswith(SUMMARY))
        need(last_case < summary_index < lines.index(OK) < lines.index(SHUTDOWN), 'green receipt ordering')
    return rows


def self_test():
    rows = []
    for width, lyrics, opening in EXPECTED:
        rest = .25 if lyrics else 0
        ps = [rest + (1-rest)*i/4 for i in range(5)]
        if not opening: ps.reverse()
        cs = [dict(revision=i, observed=i/60, progress=p, left=-100-40*p, right=100+40*p, rawWidth=200+104*p) for i,p in enumerate(ps)]
        rows.append(dict(notchWidth=width, lyricsSelected=lyrics, opening=opening, restProgress=rest, target=ps[-1], ordered=True, allPaintsMatched=True, sidesMonotonic=True, intermediateCommits=3, intermediatePaints=2, commits=cs))
    def green(rs):
        return '\n'.join([CASE+json.dumps(r) for r in rs]+[SUMMARY+json.dumps(dict(schema=1,cases=8,naturalPaint=True,nativeLocalEvents=True,scanout=False)),OK,SHUTDOWN])
    good=green(rows); validate(good); count=1
    bad=[]
    for key,value in [('ordered',False),('allPaintsMatched',False),('intermediateCommits',4),('intermediatePaints',1),('sidesMonotonic',False),('restProgress',.2),('target',.9),('opening',1)]:
        r=copy.deepcopy(rows);r[0][key]=value;bad.append(green(r))
    for key,value in [('observed',-1),('progress',float('nan')),('rawWidth',1),('left',float('inf')),('revision',0)]:
        r=copy.deepcopy(rows);r[0]['commits'][2][key]=value;bad.append(green(r))
    bad += [good.replace('"naturalPaint": true','"naturalPaint": 1'),good.replace('"cases": 8','"cases": true'),good+'\nprefix '+CASE+json.dumps(rows[0]), good+'\n'+CASE.rstrip(': '), good+'\nprefix '+SUMMARY+'{}', good.replace('"schema": 1','"schema": true'), green(rows[:-1]),green(rows+[rows[0]]),good+'\n'+OK,good.replace(SHUTDOWN,''),good+'\nOTHER_FAILED: bad',good+'\nFatal error: bad',good.replace('"ordered": true','"ordered": true, "ordered": true',1)]
    for text in bad:
        try: validate(text)
        except (ValueError,KeyError,TypeError): count+=1
        else: raise ValueError('accepted invalid green')
    rr=copy.deepcopy(rows[0]);rr['commits'][2]['left']=-105;rr['commits'][2]['right']=105;rr['commits'][2]['rawWidth']=210+24*rr['commits'][2]['progress'];rr['sidesMonotonic']=False
    red=CASE+json.dumps(rr)+'\n'+FAIL+'\n'+FAILED_SHUTDOWN
    validate(red,red=True);count+=1
    for code,text in [(1,red),(-11,red),(0,''),(0,red.replace(FAIL,FAIL+' extra')),(0,red+'\n'+FAIL),(0,red+'\n'+OK),(0,red.replace(FAIL,'MUSIC_STATIONARY_HOVER_FAILED: width-natural-endpoint')),(0,red.replace('"allPaintsMatched": true','"allPaintsMatched": false')),(0,red.replace('"sidesMonotonic": false','"sidesMonotonic": true')),(0,good),(0,red+'\nerror: bad'),(0,red.replace(CASE+json.dumps(rr),CASE+json.dumps(rows[0])))]:
        try: validate(text,code,red=True)
        except (ValueError,KeyError,TypeError): count+=1
        else: raise ValueError('accepted invalid old red')
    for stderr in (CASE+'{}', SUMMARY+'{}', OK, FAILED_SHUTDOWN, 'fatal error: bad'):
        try: validate(good, stderr=stderr)
        except ValueError: count+=1
        else: raise ValueError('accepted stderr receipt/runtime error')
    print(f'MUSIC_DETAILS_WIDTH_SELF_TEST_OK: assertions={count} nativeAppRun=false')


def red_green():
    candidate_binary = ROOT / "dist/Codex Notch Meter.app/Contents/MacOS/CodexNotchMeter"
    need(candidate_binary.is_file(), "existing packaged candidate binary required; no candidate rebuild")
    # Reuse only the already audited bounded child/log mechanism, not its ABBA logic.
    spec=importlib.util.spec_from_file_location('width_owned',ROOT/'Scripts/check-indicator-scheduler-experiment.py')
    owned=importlib.util.module_from_spec(spec);spec.loader.exec_module(owned)
    need(subprocess.check_output(['git','rev-parse',BASE+'^{commit}'],cwd=ROOT,text=True).strip()==BASE,'immutable baseline unavailable')
    archive=subprocess.check_output(['git','archive','--format=tar',BASE],cwd=ROOT)
    output=ROOT/'dist/music-details-width'; need(not output.exists(),'refuse to overwrite prior evidence; use a clean explicit experiment workspace')
    output.mkdir(parents=True)
    with tempfile.TemporaryDirectory(prefix='width-old-',dir=output) as directory:
        stage=Path(directory)
        with tarfile.open(fileobj=io.BytesIO(archive)) as source:
            for entry in source.getmembers():
                p=Path(entry.name);need(not p.is_absolute() and '..' not in p.parts and (entry.isfile() or entry.isdir()),'safe baseline archive')
                dest=stage/p
                if entry.isdir():dest.mkdir(parents=True,exist_ok=True)
                else:
                    dest.parent.mkdir(parents=True,exist_ok=True);dest.write_bytes(source.extractfile(entry).read());dest.chmod(entry.mode&0o777)
        harness=(ROOT/FIXTURE).read_bytes();(stage/FIXTURE).write_bytes(harness)
        (output/'source.json').write_text(json.dumps(dict(baseline=BASE,overlay=FIXTURE,overlaySHA256=hashlib.sha256(harness).hexdigest(),productionOverlay=False,globalSystemInput=False,scanout=False),indent=2))
        for label,tree in [('old',stage),('candidate',ROOT)]:
            if label == 'old':
                build=owned.run_owned(['swift','build','--product','CodexNotchMeter'],tree,300,8*1024*1024);owned.store_run(output/(label+'-build'),build)
                need(build['returncode']==0 and not build['timedOut'] and not build['outputLimited'],'build failed; inconclusive-stop')
                binpath=subprocess.check_output(['swift','build','--show-bin-path'],cwd=tree,text=True,timeout=30).strip()
                binary=Path(binpath)/'CodexNotchMeter'
            else:
                binary=candidate_binary
            work=output/label;work.mkdir()
            (work/'binary.json').write_text(json.dumps(dict(sha256=hashlib.sha256(binary.read_bytes()).hexdigest(), sourceHashes={str(p.relative_to(tree)):hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted((tree/'Sources').rglob('*')) if p.is_file()}, packageSHA256=hashlib.sha256((tree/'Package.swift').read_bytes()).hexdigest()),indent=2))
            run=owned.run_owned([str(binary),*FLAGS],work,65);owned.store_run(work,run)
            # Keep native receipts in official job logs too, even if a later
            # whole-job timeout prevents the final artifact-upload step.
            print('MUSIC_DETAILS_WIDTH_LOG_BEGIN: '+label, flush=True)
            print(run['stdout'], end='', flush=True)
            print(run['stderr'], end='', file=sys.stderr, flush=True)
            print('MUSIC_DETAILS_WIDTH_LOG_END: '+label, flush=True)
            need(not run['timedOut'] and not run['outputLimited'],'native evidence incomplete; inconclusive-stop')
            validate(run['stdout'],run['returncode'],red=label=='old',stderr=run['stderr'])
    print('MUSIC_DETAILS_WIDTH_RED_GREEN_OK: synthetic=true globalSystemInput=false scanout=false releaseEligible=false')


def main():
    if sys.argv[1:] in ([],['--self-test']):self_test()
    elif sys.argv[1:]==['--red-green']:red_green()
    else:raise ValueError('usage: [--self-test | --red-green]; default never launches native code')


if __name__=='__main__':
    try:main()
    except (ValueError,KeyError,TypeError,OSError,subprocess.SubprocessError) as error:
        print('MUSIC_DETAILS_WIDTH_FAILED: inconclusive-stop: '+str(error),file=sys.stderr);sys.exit(1)
