#!/usr/bin/env python3
"""Read-only offline verification of archived installed-card P0 receipts."""
import argparse
from collections import Counter
import hashlib
import json
import math
from pathlib import Path, PurePosixPath
import re
import tarfile
from uuid import UUID


GATES = (('roundTrip', 2), ('ten', 10), ('fifty', 50))
ARCHIVE = 'original-receipts.tar.gz'
MAX_GAP = 0.45  # WindowServer navigation sampling, distinct from the physical frame deadline.
OWNERS = {'net.example.spaces-document', 'net.example.spaces-route-witness',
          'org.nearpane.acceptance.LifecycleWindow'}
COORDS = ('pid', 'birth', 'number')
ACTION_DIR = re.compile(r'(roundTrip|ten|fifty)-[0-9]{2}')
JOURNAL = re.compile(r'[0-9a-fA-F-]{36}\.json')


def need(condition, reason):
    if not condition:
        raise ValueError(reason)


def positive(value):
    return type(value) in (int, float) and math.isfinite(value) and value > 0


def stream_digest(stream):
    sha = hashlib.sha256()
    for block in iter(lambda: stream.read(1024 * 1024), b''):
        sha.update(block)
    return sha.hexdigest()


def read_archive(directory):
    manifest = json.loads((directory / 'original-receipts-manifest.json').read_bytes())
    need(manifest['archive'] == ARCHIVE, 'unexpected archive filename')
    entries = {entry['file']: entry for entry in manifest['files']}
    need(len(entries) == len(manifest['files']), 'duplicate manifest member')
    data, seen = {}, set()
    with (directory / ARCHIVE).open('rb') as source:
        digest = stream_digest(source)
        need(digest == manifest['archiveSHA256'], 'archive SHA-256 mismatch')
        source.seek(0)
        with tarfile.open(fileobj=source, mode='r|gz') as tar:
            for member in tar:
                name = member.name
                need(member.isfile() and name not in seen and name in entries and
                     all(part not in ('', '.', '..') for part in name.split('/')), 'unexpected or duplicate tar member')
                seen.add(name)
                entry = entries[name]
                need(member.size == entry['bytes'], f'{name}: size mismatch')
                with tar.extractfile(member) as stream:  # No filesystem extraction.
                    if name.endswith(('.json', '.jsonl')):
                        data[name] = stream.read()
                        actual = hashlib.sha256(data[name]).hexdigest()
                    else:
                        actual = stream_digest(stream)
                need(actual == entry['sha256'], f'{name}: SHA-256 mismatch')
    need(seen == entries.keys(), 'archive is missing manifest members')
    return digest, len(seen), data


def check_ordinary_leases(data, enrollment):
    top = enrollment['topology']
    records = {str(row['id']): row for row in top['records']}
    ledger = {json.loads(data[f'ordinary-lease/desktop-{n}.json'])['sha256'] for n in (1, 2)}
    for space in enrollment['windows']:
        raw = data[f'ordinary-lease/creation-evidence/{space}/created.json']
        creation = json.loads(raw)
        before, after = creation['intent']['initial'], creation['after']
        need(hashlib.sha256(raw).hexdigest() in ledger and creation['target'] == space
             and creation['intent']['display'] == top['display'] and space not in before['spaceUUIDs']
             and records[space]['type'] == 0 and after['spaceUUIDs'] == {**before['spaceUUIDs'], space: records[space]['uuid']}
             and [s for s in after['sideOrder'] if s != space] == before['sideOrder'] and after['sideOrder'].count(space) == 1,
             'ordinary endpoint has no matching creation receipt or original Space order changed')


def enrolled_pair(request, sample, enrollment, install, original):
    host, topology = install['host'], request['topology']
    source, target = sample['source'], sample['target']
    display, records = topology['display'], topology['records']
    need((request['hostPID'], request['hostBirth'], request['hostHash']) ==
         (host['pid'], host['birth'], host['hash']), 'installed Host PID, birth or CDHash changed')
    need((topology['current'], request['target']) == (source, target) and
         topology == dict(enrollment['topology'], current=source) and request['hid'] == original['hid']
         and len(request['hid']) == 8, 'sample endpoints, topology or HID differ from admission')
    spaces = [row['id'] for row in records]
    need(len(set(spaces)) == len(spaces) == len({UUID(row['uuid']) for row in records})
         and source in spaces and target in spaces and abs(spaces.index(source) - spaces.index(target)) == 1,
         'target is not the uniquely identified adjacent Space')
    need(set(enrollment['windows']) == {str(source), str(target)}, 'Space is outside the enrolled pair')
    for space, key in ((source, 'sourceWindow'), (target, 'targetWindow')):
        window = request[key]
        path = PurePosixPath(window['executable'])
        need(window == enrollment['windows'][str(space)] and window['identifier'] in OWNERS
             and len(path.parts) > 4 and path.parts[:3] == ('/', 'private', 'tmp') and path.parts[3].startswith('nearpane-d01.')
             and '..' not in path.parts and re.fullmatch('[0-9a-f]{40}', window['hash'])
             and all(type(window[k]) is int and window[k] > 0 for k in COORDS), 'unregistered fixture identity')
        claims = [w for w in enrollment['witnesses'] if all(w[k] == window[k] for k in COORDS)]
        need(len(claims) == 1 and claims[0]['standard'] is True and claims[0]['forward'] is True
             and claims[0]['reverse'] == [space], 'fixture is not uniquely witnessed on its enrolled Space')
    need(request['sourceWindow']['number'] != request['targetWindow']['number'], 'source and target are the same window')
    UUID(display)
    return {r['id']: r for r in records}


def host_gesture(filename, record, request, spaces, pressed, used):
    intent, reply = record['intent'], record['result']
    uid = UUID(filename[:-5])
    need(uid == UUID(intent['id']) == UUID(reply['id']) and uid not in used, 'Host journal UUID mismatch or reuse')
    used.add(uid)
    top, window = request['topology'], request['targetWindow']
    source, target, display = top['current'], request['target'], top['display']
    need(intent['action'] == 'select' and intent['display'] == display and intent['window'] == {k: window[k] for k in COORDS}
         and intent['source'] == str(source) and intent['target'] == str(target)
         and all(intent[p + 'UUID'] == spaces[s]['uuid'] and intent[p + 'Kind'] == spaces[s]['type']
                 for p, s in (('source', source), ('target', target))), 'wrong formal select intent or window')
    trace = reply.get('switchTrace') or {}
    ticks = trace.get('phasesMachTicks') or []
    issued = (reply.get('submittedSteps') == 1 and trace.get('adapter') == 27 and len(ticks) == 3
              and all(type(t) is int and t > 0 for t in ticks) and ticks[0] < ticks[1] < ticks[2])
    if reply.get('state') != 'confirmed':
        return issued, False
    before, after = {display: str(source)}, {display: str(target)}
    observations = trace.get('observations', [])
    times = [r['uptime'] for r in observations]
    created, issued_at, confirmed = intent['createdAtUptime'], reply['issuedAtUptime'], reply['confirmedAtUptime']
    visits = [o['currents'] == after for o in observations]
    need(issued and reply.get('canSwitch') is True and pressed <= created <= issued_at <= confirmed and reply['currentBefore'] == before
         and reply['currentAfter'] == after and times and times == sorted(times) and issued_at <= times[0]
         and times[-1] <= confirmed and all(o['currents'] in (before, after) for o in observations)
         and visits == sorted(visits) and observations[-1]['currents'] == after,
         'Host confirmation, gesture phases or timing contradicted')
    return True, True


def landing(rows, request, pressed):
    top, target = request['topology'], request['target']
    source = top['current']
    times = [r['uptime'] for r in rows]
    need(times and all(positive(t) for t in times) and all(a < b for a, b in zip(times, times[1:])),
         'missing or out-of-order WindowServer samples')
    need(rows[0].get('topology') == top and times[0] <= pressed, 'WindowServer did not witness the original source')
    last, first, count = pressed, None, 0
    owners = {request['sourceWindow']['pid'], request['targetWindow']['pid']}
    external_front = []
    for row in rows:
        stamp, state = row['uptime'], row['topology']
        need('error' not in row and state['display'] == top['display'] and state['records'] == top['records']
             and row['hid'] == request['hid'], 'HID, display or ordered Space identities changed')
        if stamp < pressed:
            need(state['current'] == source, 'target changed before AXPress')
            continue
        need(stamp - last <= MAX_GAP, 'gap in independent WindowServer samples')
        last, count = stamp, count + 1
        if row['frontPID'] not in owners:
            external_front.append(stamp)
        need(state['current'] in (source, target), 'unexpected third Space')
        if state['current'] == target:
            if first is None:
                need(row['frontPID'] == request['targetWindow']['pid'], 'target owner was not foreground at arrival')
                first = stamp
        elif first is not None:
            raise ValueError('late return to source after target arrival')
    need(first is not None and last - first >= 2.0, 'target dwell shorter than two seconds')
    return dict(latencyMS=round(1000 * (first - pressed), 2), postPressReads=count,
                externalForegroundReads=len(external_front),
                firstExternalForegroundMS=round(1000 * (external_front[0] - pressed), 2) if external_front else None)


def visual_status(data, folder, sample, pressed, ended):
    recorded = sample.get('blankScreen', 'UNKNOWN')
    raw = data.get(folder + '/visual/receipt.json')
    need(recorded in ('PASS', 'FAIL', 'UNKNOWN'), 'unrecognized physical visual status')
    if not raw:
        need(recorded == 'UNKNOWN', 'physical visual verdict has no original receipt')
        return 'UNKNOWN'
    receipt = json.loads(raw)
    if recorded in ('PASS', 'FAIL'):
        start = json.loads(data[folder + '/visual-start.json'])
        frames = json.loads(data[folder + '/visual/frames.json'])
        need(receipt['status'] == recorded and receipt.get('physicallyQualified') is True
             and receipt['frameLog'] == 'frames.json' and start['ready'] is True and start['nonce'] == receipt['nonce'] == frames['nonce']
             and (receipt['source'], receipt['target']) == (sample['source'], sample['target'])
             and (receipt['pressed'], receipt['ended']) == (pressed, ended) and 0 < pressed < ended,
             'physical visual receipt is not bound to this action')
        if recorded == 'PASS':
            checks, coverage = receipt['subchecks'], receipt['coverage']
            need(checks['continuousVisibleLight'] == checks['nativePresentationCoverage'] == 'PASS'
                 and checks['streamingTargetMatched'] is True and checks['independentTerminalTargetMatched'] is True
                 and checks['scopedNativeBlankEventsDuringPress'] == 0 and coverage['samples'] > 0
                 and coverage['from'] <= pressed < ended <= coverage['to']
                 and not coverage['uncoveredIntervals'] and 0 < coverage['maxGapMS'] <= 50,
                 'physical PASS lacks continuous presented light and terminal target evidence')
    return recorded


def verify_sample(data, folder, sample, enrollment, install, original, used):
    def read(name):
        return json.loads(data[folder + '/' + name])

    local = read('result.json')
    need(local == {k: v for k, v in sample.items() if k not in ('index', 'source', 'target')},
         'archived action result differs from results.json')
    nav = local.get('navigationStatus', local['status'])
    ax = read('ax-dispatch.json') if folder + '/ax-dispatch.json' in data else {}
    ax_issued = ax.get('issued') is True
    need(ax_issued == local['axIssued'], 'AX dispatch count mismatch')
    journals = [k.split('/')[-1] for k in data if k.startswith(folder + '/') and JOURNAL.fullmatch(k[len(folder) + 1:])]
    need(journals == ([local['hostJournalFile']] if local.get('hostJournalFile') else []),
         'unexpected, missing or multiple formal Host journals')
    need(ax_issued or not journals, 'Host journal without an AX dispatch')
    out = dict(recordedNavigation=nav, AXPress=ax_issued, gesture=False, verified=False, visual='UNKNOWN')
    if not ax_issued:
        need(nav != 'PASS' and local['hostIssued'] is False and local.get('blankScreen', 'UNKNOWN') == 'UNKNOWN',
             'undispatched action claimed success')
        return out
    req, before = read('identity.json'), read('card-before.json')
    spaces = enrolled_pair(req, sample, enrollment, install, original)
    window, pressed = req['targetWindow'], ax['uptime']
    control = f"native-space-window:{req['topology']['display']}:{req['target']}:{window['pid']}:{window['number']}"
    need(before['control'] == ax['control'] == control and before['issued'] is False
         and all(r['ready'] is True and r['visibleHitVerified'] is True for r in (before, ax))
         and positive(pressed) and before['uptime'] <= pressed <= ax['returnedUptime'], 'wrong or unverified background card')
    confirmed = False
    if journals:
        out['gesture'], confirmed = host_gesture(journals[0], read(journals[0]), req, spaces, pressed, used)
    need(out['gesture'] == local['hostIssued'], 'formal Host dispatch count mismatch')
    rows = [json.loads(line) for line in data.get(folder + '/windowserver.jsonl', b'').splitlines()]
    out['visual'] = visual_status(data, folder, sample, pressed, rows[-1]['uptime'] if rows else 0)
    try:
        readback = landing(rows, req, pressed)
    except ValueError as error:
        if nav == 'PASS':
            raise
        out['landingIssue'] = str(error)
        return out
    if nav == 'PASS':
        need(ax.get('axError') == 0 and confirmed and folder + '/pending.json' not in data,
             'claimed navigation lacks successful AX dispatch or terminal Host confirmation')
        need(readback['latencyMS'] == local['latencyMS'], 'independent landing latency disagrees with action receipt')
        out.update(verified=True, pressed=pressed, ended=rows[-1]['uptime'], **readback)
    return out


def verify(directory):
    digest, members, data = read_archive(directory)
    install, original, result = (json.loads(data[k + '.json']) for k in ('installed', 'original', 'results'))
    host = install['host']
    need(install['path'] == '/Applications/Nearpane.app' and install['team'] == 'ZB9D4T66QB'
         and host['identifier'] == 'com.holdsnow.nearpane.alpha' and host['executable'] == install['path'] + '/Contents/MacOS/NearpaneHost'
         and re.fullmatch('[0-9a-f]{40}', host['hash']) and positive(host['pid']) and positive(host['birth'])
         and install['isolatedProfile'] is True and (install['version'], install['build']) == ('5.22', '90'),
         'unexpected installed candidate identity')
    enrollment = json.loads(data['enrolled.json']) if 'enrolled.json' in data else {}
    if enrollment and result.get('setupRoute') == 'ordinary':
        check_ordinary_leases(data, enrollment)
    current = enrollment.get('topology', {}).get('current')
    need(set(result['stages']) == {name for name, _ in GATES}, 'unrecognized or missing P0 gate')
    used, folders, gates = set(), set(), {}
    previous_passed, last_ended = True, 0
    for name, expected in GATES:
        stage = result['stages'][name]
        samples = stage['samples']
        need(stage['requested'] == expected and len(samples) <= expected and (previous_passed or not samples)
             and (stage['status'] != 'NOT_RUN' or not samples),
             f'{name}: unexpected requested count or prior gate did not pass')
        actions = []
        for i, sample in enumerate(samples, 1):
            folder = f'{name}-{i:02}'
            need(sample['index'] == i and (not sample.get('axIssued') or sample['source'] == current),
                 f'{folder}: attempt order or source disagrees with the previous landing')
            folders.add(folder)
            try:
                action = verify_sample(data, folder, sample, enrollment, install, original, used)
            except (ValueError, KeyError, TypeError, IndexError) as error:
                raise ValueError(f'{folder}: {error}') from error
            actions.append(action)
            if action['verified']:
                need(last_ended < action['pressed'], f'{folder}: action observation intervals overlap')
                current, last_ended = sample['target'], action['ended']
        delays = sorted(a['latencyMS'] for a in actions if a['verified'])
        ax_count = sum(a['AXPress'] for a in actions)
        need(stage.get('navigationConfirmed', len(delays)) == len(delays) and stage.get('navigationDispatched', ax_count) == ax_count,
             f'{name}: archived stage counters disagree')
        visual = Counter(a['visual'] for a in actions)
        if stage['navigationStatus'] == 'PASS' or stage['status'] == 'PASS':
            need(len(delays) == expected, f'{name}: claimed PASS without all verified navigations')
        if stage.get('blankScreen') == 'PASS':
            need(visual['PASS'] == expected, f'{name}: stage visual PASS without all bound physical receipts')
        if stage['status'] == 'PASS':
            need(stage['navigationStatus'] == 'PASS' and (name != 'ten' or visual['PASS'] == expected),
                 f'{name}: claimed gate PASS without required visual or navigation evidence')
        previous_passed = stage['status'] == 'PASS'
        latency = {k: delays[math.ceil(len(delays) * p) - 1] for k, p in
                   (('p50', .50), ('p95', .95), ('p99', .99))} if delays else None
        need('latencyMS' not in stage or stage['latencyMS'] == latency, f'{name}: stored percentiles disagree')
        gates[name] = dict(recordedGate=stage['status'], recordedNavigation=stage['navigationStatus'],
                           recordedVisual=stage.get('blankScreen', 'UNKNOWN'), requested=expected, attempted=len(actions),
                           AXPress=ax_count, gestureSequences=sum(a['gesture'] for a in actions),
                           verifiedNavigations=len(delays), visualByAttempt=dict(visual),
                           postPressWindowServerReads=sum(a.get('postPressReads', 0) for a in actions),
                           externalForeground=[dict(index=i, reads=a['externalForegroundReads'], firstMS=a['firstExternalForegroundMS'])
                                               for i, a in enumerate(actions, 1) if a.get('externalForegroundReads')],
                           unverifiedReadbacks=[dict(index=i, reason=a['landingIssue']) for i, a in enumerate(actions, 1)
                                                if 'landingIssue' in a], latencyMS=latency)
    need(folders == {p.split('/')[0] for p in data if ACTION_DIR.fullmatch(p.split('/')[0])},
         'unreported or missing action folder')
    need(result.get('blankScreen') != 'PASS' or gates['ten']['recordedVisual'] == 'PASS',
         'overall visual PASS without ten verified physical receipts')
    need(result['status'] != 'PASS' or all(s['recordedGate'] == 'PASS' for s in gates.values()),
         'overall PASS without all gates')
    return dict(archive=directory.name, verification='VERIFIED', sha256=digest, hashedMembers=members,
                hostCDHash=host['hash'], uniqueHostJournals=len(used), recordedStatus=result['status'], stages=gates)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('archive_directories', nargs='+', type=Path)
    failed = False
    for directory in parser.parse_args().archive_directories:
        try:
            report = verify(directory)
        except (OSError, EOFError, ValueError, KeyError, TypeError, IndexError, tarfile.TarError) as error:
            failed = True
            report = dict(archive=directory.name, verification='INVALID', reason=str(error))
        print(json.dumps(report, ensure_ascii=False))
    return int(failed)


if __name__ == '__main__':
    raise SystemExit(main())
