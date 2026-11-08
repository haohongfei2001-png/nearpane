import Foundation

@MainActor protocol SystemCaptureProcess: AnyObject {
    func start(output: URL, ended: @escaping @MainActor @Sendable (Int32) async -> Void) throws
    func terminate()
}

@MainActor final class MacSystemCaptureProcess: SystemCaptureProcess {
    private let process = Process()

    func start(output: URL, ended: @escaping @MainActor @Sendable (Int32) async -> Void) throws {
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-i", "-t", "png", output.path]
        process.terminationHandler = { child in
            let status = child.terminationStatus
            child.terminationHandler = nil
            Task { @MainActor in await ended(status) }
        }
        do { try process.run() }
        catch { process.terminationHandler = nil; throw error }
    }

    func terminate() {
        if process.isRunning { process.terminate() }
    }
}

@MainActor final class SystemCaptureJob {
    let process: any SystemCaptureProcess
    // Remains installed while the child has exited but its import/notification is suspended.
    var owner: TrayOwner?
    var completing = false
    init(_ process: any SystemCaptureProcess) { self.process = process }
}
