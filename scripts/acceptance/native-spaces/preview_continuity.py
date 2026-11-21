"""Check a presented card for neutral translucent pixels while its enrolled source is opaque and colored."""
from bisect import bisect_left


def uniform_rgba(sample):
    value = sample.get("median")
    if (not isinstance(value, list) or len(value) != 4 or sample.get("dominantFraction") != 1
            or sample.get("minimum") != value or sample.get("maximum") != value):
        return None
    return value


def confirmed_source(left, right, document):
    a, b = left["samples"][0], right["samples"][0]
    rgb_a, rgb_b = uniform_rgba(a), uniform_rgba(b)
    return (left["basis"] == right["basis"] == "SCDisplayTime" and rgb_a is not None and rgb_b is not None
            and rgb_a[3] == rgb_b[3] == 255 and a["color"] == b["color"]
            and a["color"].startswith(f"{document}/") and min(max(rgb[:3])-min(rgb[:3]) for rgb in (rgb_a,rgb_b)) > 2)


def measured_intervals(streams, maximum_join):
    windows = []
    for document in range(2):
        source = streams[document]
        source_times = [f["time"] for f in source]
        confirmed, unpaired, singletons = [], 0, 0
        active = []

        def finish():
            nonlocal singletons
            if len(active) > 1:
                confirmed.append(dict(first=active[0]["time"], last=active[-1]["time"], frames=len(active),
                                      observedSpanMs=round((active[-1]["time"]-active[0]["time"])*1000, 3),
                                      firstPanelSequence=active[0]["sequence"], lastPanelSequence=active[-1]["sequence"]))
            elif active:
                singletons += 1
            active.clear()

        for panel in streams[2]:
            center = uniform_rgba(panel["samples"][document])
            if (not center or center[3] == 255 or max(center[:3])-min(center[:3]) > 2
                    or panel["basis"] != "SCDisplayTime"):
                finish()
                continue
            t = panel["time"]
            i = bisect_left(source_times, t)
            if (i == 0 or i == len(source) or t-source_times[i-1] > maximum_join or source_times[i]-t > maximum_join
                    or not confirmed_source(source[i-1],source[i],document)):
                unpaired += 1
                finish()
                continue
            if active and t-active[-1]["time"] > 2*maximum_join:
                finish()
            active.append(panel)
        finish()
        windows.append(dict(document=document, confirmed=confirmed, singleFrameObservations=singletons,
                            neutralFramesWithoutQualifiedSourceBracket=unpaired))
    status = "FAIL" if any(w["confirmed"] for w in windows) else "NO_CONFIRMED_INTERVAL"
    return dict(status=status, windows=windows, maximumSourceToPanelJoinSeconds=maximum_join,
                scope="Only uniform translucent neutral card patches with bracketing opaque fixture colors.")
