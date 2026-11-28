import Foundation

@MainActor protocol SystemCaptureProcess: AnyObject {
    func start(output: URL, ended: @escaping @MainActor @Sendable (Int32) async -> Void) throws
    func terminate()
}

@MainActor final class MacSystemCaptureProcess: SystemCaptureProcess {
    private let process = Process()
    private let ownedWindow: (@MainActor () throws -> UInt32)?
    init(ownedWindow: (@MainActor () throws -> UInt32)? = nil) { self.ownedWindow = ownedWindow }

    func start(output: URL, ended: @escaping @MainActor @Sendable (Int32) async -> Void) throws {
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        let target = try ownedWindow?()
        if let target { process.arguments = ["-x", "-o", "-l", String(target), "-t", "png", output.path] }
        else { process.arguments = ["-i", "-t", "png", output.path] }
        process.terminationHandler = { [ownedWindow] child in
            let status = child.terminationStatus
            child.terminationHandler = nil
            Task { @MainActor [ownedWindow] in
                if let target, (try? ownedWindow?()) != target {
                    try? FileManager.default.removeItem(at: output)
                    await ended(1)
                } else { await ended(status) }
            }
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
