"""Measure independently observed synthetic source and matching sidebar color transitions."""
from collections import Counter
import math


EPOCHS = 7


def percentiles(values):
    values = sorted(values)
    if not values:
        return None
    return {name: round(values[math.ceil(len(values)*q)-1], 2)
            for name, q in (("p50", .50), ("p95", .95), ("p99", .99), ("max", 1.0))}


def earliest_sample(observation):
    t = observation.get('displayTime')
    return min(observation['start'], t) if t is not None else observation['start']


def transitions(series, doc):
    colors = [s['color'] for s in series]
    events = {}
    for epoch in range(1, EPOCHS):
        old, new = f'{doc}/{epoch-1}', f'{doc}/{epoch}'
        for i in range(1, len(series)-1):
            if colors[i:i+2] != [new, new]:
                continue
            previous = next((j for j in range(i-1, -1, -1) if colors[j] == old), None)
            if previous is not None:
                # The old image was sampled sometime during that request and the new image
                # by the first successful reply. Recording only this interval avoids inventing a presentation timestamp.
                events[epoch] = (earliest_sample(series[previous]), series[i]['end'])
            break
    return events


def summarize(batches):
    streams = [[] for _ in range(4)]
    for row in batches:
        if len(row) != 4 or any(row[2].get(k) != row[3].get(k) for k in ('start', 'end', 'displayTime', 'frameStatus')):
            raise ValueError('sidebar patches do not share one captured frame')
        for observation, series in zip(row, streams):
            a, b = observation['start'], observation['end']
            if not all(isinstance(v, (int, float)) and math.isfinite(v) and v >= 0 for v in (a, b)) or b < a or (series and a < series[-1]['end']):
                raise ValueError('invalid capture clock')
            presented = observation.get('displayTime')
            if presented is not None and (not isinstance(presented, (int,float)) or not math.isfinite(presented) or presented <= 0 or presented > b+.005):
                raise ValueError('unverified display-time clock')
            if observation['color'] not in {'unknown', 'blank', *(f'{d}/{e}' for d in range(2) for e in range(EPOCHS))}:
                raise ValueError('unknown fixture code')
            series.append(observation)
    windows, latencies = [], []
    for doc in range(2):
        source, picture = streams[doc], streams[2+doc]
        src, dest = transitions(source, doc), transitions(picture, doc)
        trials = []
        for epoch in range(1, EPOCHS):
            target=f'{doc}/{epoch}'
            trial={'epoch':epoch, 'outcome':'UNKNOWN', 'sourceBracket':src.get(epoch), 'pictureBracket':dest.get(epoch)}
            if epoch in src:
                lo,hi = src[epoch]
                known_until = max((earliest_sample(s) for s in source if s['color']==target), default=hi)
                states = [p['color'] for p in picture if hi <= earliest_sample(p) and p['end'] <= known_until]
                trial['duringConfirmedSource'] = dict(Counter(states))
                trial['consecutiveBlankSamples'] = any(a=='blank' and b=='blank' for a,b in zip(states, states[1:]))
                if any(s.startswith(f'{1-doc}/') for s in states):
                    trial['outcome'] = 'WRONG_WINDOW'
                elif epoch in dest and dest[epoch][1] >= lo:
                    lower = max(0.,1000*(dest[epoch][0]-hi)); upper = 1000*(dest[epoch][1]-lo)
                    trial.update(outcome='MATCH', latencyMs=[round(lower,3), round(upper,3)])
                    latencies.append((lower,upper))
                elif len(states)>=2 and all(s=='blank' for s in states):
                    trial['outcome'] = 'BLANK'
                elif len(states)>=2 and all(s.startswith(f'{doc}/') and s!=target for s in states):
                    trial['outcome'] = 'STALE'
            trials.append(trial)
        matched=[t['latencyMs'] for t in trials if 'latencyMs' in t]
        windows.append({'document':doc, 'events':trials,'outcomes':dict(Counter(t['outcome'] for t in trials)),
                        'sourceSampleCounts':dict(Counter(p['color'] for p in source)),
                        'pictureSampleCounts':dict(Counter(p['color'] for p in picture)),
                        'blankSamples':sum(p['color']=='blank' for p in picture), 'unknownSamples':sum(p['color']=='unknown' for p in picture),
                        'wrongWindowSamples':sum(p['color'].startswith(f'{1-doc}/') for p in picture),
                        'latencyMs':{'n':len(matched),'lower':percentiles([v[0] for v in matched]),'upper':percentiles([v[1] for v in matched])}})
    together = []
    for epoch in range(EPOCHS):
        target = [f'0/{epoch}', f'1/{epoch}']*2
        agreeing = [[x['color'] for x in row]==target for row in batches]
        together.append({'epoch':epoch, 'matchingFrames':sum(agreeing), 'twoConsecutive':any(a and b for a,b in zip(agreeing,agreeing[1:]))})
    results=[t['outcome'] for w in windows for t in w['events']]
    failure = any(s in {'WRONG_WINDOW','BLANK','STALE'} for s in results) or any(w['wrongWindowSamples'] for w in windows)
    success = all(s=='MATCH' for s in results) and all(p['twoConsecutive'] for p in together)
    return {'status': 'FAIL' if failure else 'PASS' if success else 'INCONCLUSIVE', 'windows':windows,'simultaneous':together,
            'sampling':{'batches':len(batches),'samePanelFrame':True,'panelFramesWithDisplayTime':sum(o.get('displayTime') is not None for o in streams[2]),
                        'blankMeaning':'neutral or transparent marker pixels in a real capture; unreadable buffers are unknown',
                        'captureWindowMs':percentiles([1000*(o['end']-o['start']) for row in batches for o in row]),
                        'panelSampleGapMs':percentiles([1000*(b['start']-a['start']) for a,b in zip(streams[2],streams[2][1:])])},
            'latencyMs':{'method':'interval bounds from independently sampled color changes; nearest-rank percentiles on matched transitions',
                         'n':len(latencies),'lower':percentiles([v[0] for v in latencies]),'upper':percentiles([v[1] for v in latencies])},
            'nativeStageManagerComparison':{'status':'NOT_MEASURED','latencyMs':None}}
