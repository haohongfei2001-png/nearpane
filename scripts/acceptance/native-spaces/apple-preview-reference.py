#!/usr/bin/env python3
"""Inspect enrolled pixel channels of archived macOS paired-preview runs; never opens a display or an app."""
import argparse
import gzip
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
PACKET = ROOT / 'engineering/verification/native-spaces/5.22-90-active-display-previews'


def check(valid, why):
    if not valid:
        raise ValueError(why)


def file_json(path):
    with path.open('rb') as stream:
        return json.load(stream)


def enrolled_streams(run):
    a, b, app, fixture = (run[k] for k in ('binding', 'finalBinding', 'installed', 'fixture'))
    keys = ('hostPID', 'hostBirth', 'hostHash', 'panel', 'fixturePID', 'fixtureBirth', 'fixtureHash', 'numbers', 'display', 'space', 'sources', 'pictures')
    check(all(a[k] == b[k] for k in keys) and app['bundle'] == 'com.holdsnow.nearpane.alpha' and
          app['pid'] == a['hostPID'] and app['cdHash'] == a['hostHash'] and fixture['kernelGenerationMatches'] is True and
          fixture['pid'] == a['fixturePID'] and fixture['birth'] == a['fixtureBirth'] and fixture['numbers'] == a['numbers'],
          'recordedWindowGenerationChanged')
    numbers = a['numbers']
    check(len(numbers) == 2 and len(set([*numbers, a['panel']])) == 3 and a['hostPID'] != a['fixturePID'], 'ownersOrSourcesAmbiguous')
    for snap in (a, b):
        evidence = snap['windowCensus']['expectedEvidence']
        check(snap['stageManager'] is False and snap['cardIdentityProven'] is True and snap['present'] == [True, True] and
              snap['windowCensus']['admitted'] is True and sorted(r['number'] for r in evidence) == sorted(numbers) and
              all(r['accepted'] is True and r['axStandard'] is True and r['forward'] is True and r['reverse'] == [snap['space']] for r in evidence),
              'sourceSpaceOrProductionCardScopeUnconfirmed')
    filters = [e['filterGeometry'] for e in run['sampler']['events'] if 'filterGeometry' in e]
    check(len(filters) == 1 and len(filters[0]) == 3, 'unknownChannelRosterInspectBeforeAttribution')
    windows = [*numbers, a['panel']]
    for i, f in enumerate(filters[0]):
        expected_mode = 'desktopIndependentFixtureWindow' if i < 2 else 'visibleDisplayWindow'
        expected_areas = [a['sources'][i]] if i < 2 else a['pictures']
        check(f['window'] == windows[i] and f['mode'] == expected_mode and f['includedWindowCount'] == 1 and
              f['sampledGlobalRects'] == expected_areas, 'unexpectedCaptureTargetInspectBeforeAttribution')
    return windows


def pixel_counts(path, manifest):
    counts = [0, 0, 0]
    clocked = [0, 0, 0]
    digest = hashlib.sha256()
    opener = gzip.open if path.suffix == '.gz' else open
    with opener(path, 'rb') as stream:
        for raw in stream:
            digest.update(raw)
            f = json.loads(raw)
            channel = f['channel']
            check(type(channel) is int and channel in (0, 1, 2), 'unattributedPixelChannel')
            counts[channel] += 1
            check(f['sequence'] == counts[channel], 'channelSequenceInterrupted')
            if (f['qualified'] is True and f['status'] == 0 and len(f['samples']) == (2 if channel == 2 else 1) and
                    isinstance(f.get('displayTicks'), int) and f['displayTicks'] > 0 and isinstance(f.get('displayTime'), (int, float))):
                clocked[channel] += 1
    check(digest.hexdigest() == manifest['sha256'] and sum(counts) == manifest['count'] and all(clocked), 'frameLedgerChecksumOrCountMismatch')
    return clocked


def audit(folder, stage_path, mission_path):
    run = file_json(folder / 'result.json')
    windows = enrolled_streams(run)
    manifest = run['presentation']
    check(manifest['frames'] == 'presentation-frames.jsonl', 'unexpectedFrameLedgerName')
    path = folder / manifest['frames']
    clocked = pixel_counts(path if path.is_file() else path.with_suffix('.jsonl.gz'), manifest)
    stage = file_json(stage_path)
    check(stage['status'] == 'PASS' and all(stage[k]['observed']['stageManager'] is True and
          stage[k]['host']['stageManagerOwnsDispatch'] == 1 and stage[k]['host']['activeStreams'] == 0 for k in ('before', 'after')),
          'stageOnRuntimeReceiptUnconfirmed')
    lease = file_json(folder / 'lease.json')
    inactive = {(r['ownerBirth'], r['number']) for k in ('admission', 'afterFixture') for step in lease.get(k, [])
                for r in step.get('inactiveStageSurfaces', []) if r['category'] == 'offscreenSignedWindowManagerSurface' and
                r['admitted'] is True and r['publicOnscreen'] is False and r['listedAsOwnDocument'] is False and r['pixels'] == 0}
    mission = file_json(mission_path)
    check(mission['event'] == 'overviewDismissal' and type(mission['linkedFixtureButton']) is bool, 'invalidHistoricalOverviewObservation')
    return {
        'nativeStageManagerComparison': {'status': 'NOT_MEASURED', 'latencyMs': None, 'nativePresentationSamples': 0,
                                         'scope': 'archivedPairedRunFrameLedger', 'reason': 'noEnrolledAppleThumbnailPixelChannel'},
        'pairedRun': {'source': run['installed']['source'], 'build': run['installed']['build'], 'stageManager': False,
                      'matchedNearpaneTransitionsReported': run['metrics']['latencyMs']['n'], 'sha256OfFrameLedger': manifest['sha256'],
                      'pixelChannels': [dict(channel=i, owner='Field Notes' if i < 2 else 'installed Nearpane',
                                             window=w, qualifiedCompleteFramesWithDisplayTime=clocked[i]) for i,w in enumerate(windows)]},
        'stageOn': {'sameHostRevisionAsPair': stage['source'] == run['installed']['source'], 'hostActiveStreams': [0, 0],
                    'verifiedOffscreenWindowManagerSurfacesInLease': len(inactive), 'pixelsFromThoseSurfaces': 0},
        'separateMissionControlObservation': {'time': mission['at'], 'linkedFixtureButton': mission['linkedFixtureButton'],
                                              'sameTrialAsPair': False, 'pixelClockSamples': None},
    }


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('folder', nargs='?', type=Path, default=PACKET/'physical-09')
    parser.add_argument('--stage-on', type=Path, default=PACKET/'physical-08/installed-stage-manager.json')
    parser.add_argument('--mission-observation', type=Path, default=PACKET/'apple-reference/mission-observation.jsonl')
    args = parser.parse_args()
    try:
        print(json.dumps(audit(args.folder, args.stage_on, args.mission_observation), indent=2, ensure_ascii=False))
    except (OSError, KeyError, TypeError, ValueError, IndexError) as e:
        parser.exit(2, f'Cannot qualify the archive ({type(e).__name__}: {e}).\n')
