import AppKit
import Darwin
import Foundation
import LyricPlayback

/// Explicit local observation mode in the same signed app, so diagnostics do not
/// substitute a differently signed command-line bridge for the real product.
@MainActor
final class LyricDiagnosticApplicationDelegate: NSObject, NSApplicationDelegate {
    private var task: Task<Void, Never>?
    private var signals: [DispatchSourceSignal] = []
    static var requested: Bool { CommandLine.arguments.contains("--diagnostics") }

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            let options = try Options(arguments: Array(CommandLine.arguments.dropFirst()))
            for number in [SIGINT, SIGTERM] {
                signal(number, SIG_IGN)
                let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
                source.setEventHandler { [weak self] in Task { @MainActor [weak self] in self?.task?.cancel() } }
                source.resume(); signals.append(source)
            }
            task = Task {
                do {
                    let result = try await PlaybackController.collectDiagnostics(player: options.player,
                        seconds: options.seconds, outputDirectory: options.output)
                    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
                    print(String(decoding: try encoder.encode(result), as: UTF8.self))
                    Darwin.exit(EXIT_SUCCESS)
                } catch {
                    let report: [String: String] = ["status": "NOT_QUALIFIED", "error": error.localizedDescription,
                                                  "scope": "real-source-observation"]
                    if let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]) {
                        FileHandle.standardError.write(data + Data([10]))
                    }
                    Darwin.exit(Task.isCancelled ? 130 : EXIT_FAILURE)
                }
            }
        } catch {
            let usage = "LyricTile --diagnostics [--player appleMusic|spotify|qqMusic|netease] --seconds 1...3600 --output /absolute/new-directory\n\(error.localizedDescription)\n"
            FileHandle.standardError.write(Data(usage.utf8)); Darwin.exit(2)
        }
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        task?.cancel() // collector awaits all helper shutdowns before exiting
        return task == nil ? .terminateNow : .terminateLater
    }
    private struct Options {
        var player: PlayerID?
        var seconds = 60
        var output: URL
        init(arguments: [String]) throws {
            var index = 0, outputPath: String?
            while index < arguments.count {
                let name = arguments[index]; index += 1
                if name == "--diagnostics" { continue }
                guard ["--player", "--seconds", "--output"].contains(name), index < arguments.count else {
                    throw NSError(domain: "LyricTile.Diagnostics", code: 2, userInfo: [NSLocalizedDescriptionKey: "Unknown or incomplete argument: \(name)"])
                }
                let value = arguments[index]; index += 1
                switch name {
                case "--player":
                    guard let selected = PlayerID(rawValue: value) else { throw Self.invalid("player") }
                    player = selected
                case "--seconds":
                    guard let n = Int(value), (1...3600).contains(n) else { throw Self.invalid("seconds") }
                    seconds = n
                default: outputPath = value
                }
            }
            guard let outputPath, outputPath.hasPrefix("/") else { throw Self.invalid("absolute output directory") }
            output = URL(fileURLWithPath: outputPath, isDirectory: true)
        }
        private static func invalid(_ field: String) -> Error {
            NSError(domain: "LyricTile.Diagnostics", code: 2, userInfo: [NSLocalizedDescriptionKey: "Invalid \(field)"])
        }
    }
}
