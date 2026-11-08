import Foundation
import Darwin
import ObservationCore

let usage = """
P1-B preparation observer (isolated, read-only; no desktop actions).
  spaces-observer fixture --output /absolute/new/private/directory
  spaces-observer observe --output /absolute/new/private/directory [--samples 12]
    [--interval-ms 500] [--stable-count 3] [--max-seconds 60]

No arguments / --help: no sampling. Only 'observe' reads the live desktop.
Output must be a NEW directory outside any repository, with no symlink components.
The parent must already exist. Directory 0700; raw.jsonl and sanitized.jsonl 0600.
Limits: samples 1...1800, interval 250...10000 ms, stable count 2...20,
duration 1...900 seconds; combined logs <= 64 MiB. Private calls cannot be preempted.
stdin accepts bounded newline-delimited operator marker JSON (see SESSION-FORMAT.md).
Markers record claims only; they never authorize or perform actions. 'stop' ends polling.
No permissions requested, pixels captured, settings changed, or windows manipulated.
"""

func run() throws {
    let arguments = Array(CommandLine.arguments.dropFirst())
    if arguments.isEmpty || arguments == ["--help"] { print(usage); return }
    guard let mode = arguments.first, ["observe", "fixture"].contains(mode), (arguments.count - 1) % 2 == 0 else {
        throw ObserverError.invalidConfiguration
    }
    var options: [String: String] = [:]
    let allowed = Set(["--output", "--samples", "--interval-ms", "--stable-count", "--max-seconds"])
    for index in stride(from: 1, to: arguments.count, by: 2) {
        let key = arguments[index]
        guard allowed.contains(key), options[key] == nil else { throw ObserverError.invalidConfiguration }
        options[key] = arguments[index + 1]
    }
    guard let directory = options["--output"] else { throw ObserverError.invalidConfiguration }
    func integer(_ key: String, _ fallback: Int, _ range: ClosedRange<Int>) throws -> Int {
        guard let value = Int(options[key] ?? String(fallback)), range.contains(value) else { throw ObserverError.invalidConfiguration }
        return value
    }
    let samples = try integer("--samples", 12, 1...1800)
    let intervalMS = try integer("--interval-ms", 500, 250...10000)
    let stableCount = try integer("--stable-count", 3, 2...20)
    let maxSeconds = try integer("--max-seconds", 60, 1...900)
    if mode == "fixture", options.keys.contains(where: { $0 != "--output" }) { throw ObserverError.invalidConfiguration }
    let config = SessionConfig(source: mode == "fixture" ? "synthetic_fixture" : "read_only_live",
                               samples: mode == "fixture" ? 12 : samples, intervalMS: intervalMS,
                               stableCount: stableCount, maxSeconds: maxSeconds)
    // Output validation/creation happens BEFORE initializing any live provider.
    let log = try PrivateSessionLog(directory: directory, maxBytes: config.maxLogBytes)
    var detector = try StableDetector(requiredSamples: stableCount, maxGapNS: UInt64(intervalMS * 3) * 1_000_000)
    try log.append(kind: "sessionStart", config: config)
    if mode == "fixture" {
        for revision in 1...12 {
            var state = SyntheticFixture.state()
            if revision == 4 {
                let marker = OperatorMarker(kind: .beforeAction, action: .nativeSpaceChange, display: .A, trial: 1,
                                            note: "SYNTHETIC-PRIVATE-NOTE")
                detector.operatorMarker()
                try log.append(kind: "operatorMarker", marker: marker)
            }
            if revision >= 4 { state.boundary.inventory.scopes[0].currentSpaceID = 8_002 }
            if revision >= 7 { state.boundary.topology.displays[0].rotation = 90 }
            if revision >= 10 {
                state.boundary.inventory.scopes[0].identifier = "SYNTHETIC-UNKNOWN-SCOPE"
                state.boundary.inventory.scopes[0].currentSpaceID = nil
                state.windows[0].membership = Membership(status: .empty)
            }
            let sample = try SyntheticFixture.sample(revision, state: state)
            try log.append(kind: "sample", sample: sample, assessment: detector.ingest(sample))
        }
        try log.append(kind: "sessionEnd", endReason: "fixture_complete")
        print("Synthetic fixture complete. Behavioral testing: NOT TESTED.")
        return
    }

    let sampler = MacSampler()
    let stdinFlags = fcntl(STDIN_FILENO, F_GETFL)
    guard stdinFlags >= 0, fcntl(STDIN_FILENO, F_SETFL, stdinFlags | O_NONBLOCK) == 0 else { throw ObserverError.ioFailure }
    defer { _ = fcntl(STDIN_FILENO, F_SETFL, stdinFlags) }
    var lines = MarkerLines(), eof = false, stop = false, markerCount = 0
    func record(_ results: [Result<OperatorMarker, ObserverError>]) throws {
        for result in results {
            markerCount += 1
            detector.operatorMarker() // Invalid input also invalidates the stable run.
            switch result {
            case .success(let marker):
                try log.append(kind: "operatorMarker", marker: marker)
                if marker.kind == .stop { stop = true }
            case .failure:
                try log.append(kind: "markerRejected")
            }
        }
    }
    func drainMarkers() throws {
        guard !eof else { return }
        // Bounded work per drain, even if stdin is continuously flooded.
        for _ in 0..<4 {
            var buffer = [UInt8](repeating: 0, count: 8192)
            let count = Darwin.read(STDIN_FILENO, &buffer, buffer.count)
            if count > 0 { try record(lines.consume(Data(buffer.prefix(count)))) }
            else if count == 0 { eof = true; try record(lines.finish()); return }
            else if errno == EAGAIN || errno == EWOULDBLOCK { return }
            else if errno != EINTR { throw ObserverError.ioFailure }
        }
    }
    let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(maxSeconds) * 1_000_000_000
    var completed = 0
    for revision in 1...samples {
        try drainMarkers()
        if stop || DispatchTime.now().uptimeNanoseconds >= deadline { break }
        let markersBeforeRead = markerCount
        var sample = try sampler.sample(revision: revision)
        // If a marker arrived during the non-atomic read, do not let that read seed a stable run.
        try drainMarkers()
        if markerCount != markersBeforeRead { sample.observerIssues.append("operator_marker_during_sample") }
        if DispatchTime.now().uptimeNanoseconds >= deadline {
            // Preserve the sample; its duration/gap policy still applies. Never start another read.
            try log.append(kind: "sample", sample: sample, assessment: detector.ingest(sample))
            completed += 1; break
        }
        // Assessment timestamps refer to API reads; marker receipt time is independent.
        try log.append(kind: "sample", sample: sample, assessment: detector.ingest(sample))
        completed += 1
        if stop { break }
        if revision == samples { break }
        let next = DispatchTime.now().uptimeNanoseconds + UInt64(intervalMS) * 1_000_000
        while DispatchTime.now().uptimeNanoseconds < min(next, deadline), !stop {
            try drainMarkers()
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
        }
    }
    try drainMarkers()
    try log.append(kind: "sessionEnd", endReason: stop ? "operator_stop" : (completed == samples ? "sample_limit" : "duration_limit"))
    print("Read-only session complete. Evidence remains in the requested private directory.")
}

do { try run() }
catch {
    // Never print arbitrary errors or input payloads: they can contain private paths/marker text.
    fputs("Observer stopped: invalid options, unsafe output, output limit, or I/O failure. Existing evidence was preserved; a missing sessionEnd means incomplete. See --help.\n", stderr)
    exit(1)
}
