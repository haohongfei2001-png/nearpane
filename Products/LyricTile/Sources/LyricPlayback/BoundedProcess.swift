import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

struct ProcessOutput: Sendable { let data: Data; let stderr: Data; let status: Int32 }

/// Owns one child from spawn through reap. Readers drain both pipes concurrently.
/// Cancellation/timeout terminates then kills the same unreaped child if needed.
final class BoundedProcess: @unchecked Sendable {
    private let process = Process()
    private let stdout = Pipe()
    private let stderr = Pipe()
    private let lock = NSLock()
    private let completion = DispatchGroup()
    private var output = Data()
    private var errorOutput = Data()
    private var failure: PlaybackError?
    private var cancelled = false
    private var launched = false
    private var finished = false
    private let limit: Int
    private let timeout: TimeInterval?
    private let chunk: (@Sendable (Data) -> Bool)?

    init(executable: URL, arguments: [String], limit: Int, timeout: TimeInterval?,
         chunk: (@Sendable (Data) -> Bool)? = nil) {
        self.limit = limit; self.timeout = timeout; self.chunk = chunk
        completion.enter()
        process.executableURL = executable; process.arguments = arguments
        // Do not inherit PERL5OPT/PERL5LIB/DYLD_* from the launching shell.
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US.UTF-8"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdout; process.standardError = stderr
    }

    func run() async throws -> ProcessOutput {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .utility).async { self.execute(continuation) }
            }
        } onCancel: { self.cancel() }
    }

    func cancel() {
        lock.lock(); cancelled = true
        let shouldTerminate = launched && !finished && process.isRunning
        if shouldTerminate { process.terminate() }
        lock.unlock()
        if shouldTerminate {
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.75) { self.killIfRunning() }
        }
    }
    func cancelAndWait() async {
        cancel()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .utility).async {
                _ = self.completion.wait(timeout: .now() + 2)
                self.killIfRunning()
                continuation.resume()
            }
        }
    }
    private func killIfRunning() {
        lock.lock(); defer { lock.unlock() }
        guard launched, !finished, process.isRunning else { return }
        #if canImport(Darwin) || canImport(Glibc)
        _ = kill(process.processIdentifier, SIGKILL)
        #endif
    }
    private func fail(_ error: PlaybackError) {
        lock.lock(); if failure == nil { failure = error }; lock.unlock(); cancel()
    }
    private func read(_ handle: FileHandle, isError: Bool) {
        do {
            while let bytes = try handle.read(upToCount: 32 * 1024), !bytes.isEmpty {
                if isError {
                    lock.lock()
                    let remaining = max(0, 64 * 1024 - errorOutput.count)
                    errorOutput.append(bytes.prefix(remaining))
                    lock.unlock()
                } else if let chunk {
                    if !chunk(bytes) { fail(.outputLimit) }
                } else {
                    lock.lock()
                    let fits = output.count + bytes.count <= limit
                    if fits { output.append(bytes) }
                    lock.unlock()
                    if !fits { fail(.outputLimit) }
                }
            }
        } catch { fail(.unavailable("媒体助手输出读取失败")) }
        try? handle.close()
    }
    private func execute(_ continuation: CheckedContinuation<ProcessOutput, any Error>) {
        defer { completion.leave() }
        lock.lock(); let shouldCancel = cancelled; lock.unlock()
        guard !shouldCancel else { continuation.resume(throwing: CancellationError()); return }
        do { try process.run() }
        catch { continuation.resume(throwing: PlaybackError.unavailable("媒体助手无法启动：\(error.localizedDescription)")); return }
        lock.lock(); launched = true; let cancelledAfterLaunch = cancelled; lock.unlock()
        // Parent must not retain a write end and prevent EOF after child exit.
        try? stdout.fileHandleForWriting.close(); try? stderr.fileHandleForWriting.close()
        if cancelledAfterLaunch { cancel() }
        let readers = DispatchGroup()
        readers.enter(); DispatchQueue.global(qos: .utility).async { self.read(self.stdout.fileHandleForReading, isError: false); readers.leave() }
        readers.enter(); DispatchQueue.global(qos: .utility).async { self.read(self.stderr.fileHandleForReading, isError: true); readers.leave() }
        let timer = DispatchWorkItem { [weak self] in self?.fail(.timeout) }
        if let timeout { DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: timer) }
        process.waitUntilExit()
        lock.lock(); finished = true; lock.unlock()
        timer.cancel()
        readers.wait()
        lock.lock()
        let result = ProcessOutput(data: output, stderr: errorOutput, status: process.terminationStatus)
        let error = failure; let wasCancelled = cancelled
        lock.unlock()
        if let error { continuation.resume(throwing: error) }
        else if wasCancelled { continuation.resume(throwing: CancellationError()) }
        else { continuation.resume(returning: result) }
    }
}
