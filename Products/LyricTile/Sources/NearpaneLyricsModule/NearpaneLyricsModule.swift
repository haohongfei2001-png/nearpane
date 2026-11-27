import AppKit
import Combine
import Foundation
import LyricUI
import LyricCore
import LyricPlayback
import SwiftUI

/// Owns a native View and the same domain services as the standalone product; no nested NSPanel.
@MainActor
public final class NearpaneLyricsModule: NSObject, ObservableObject {
    public let model: LyricAppModel
    @Published public private(set) var isPresented = false
    public var hostSurfaceDidWithdraw: (@MainActor () async -> Bool)?
    /// The Host owns all management navigation. This module never creates an NSWindow.
    public var openManagementPage: (@MainActor (LyricAuxiliaryPage) -> Void)?
    private var presentationSubscription: AnyCancellable?
    private var transitioning = false

    public init(storageURL: URL? = nil, defaults: UserDefaults = .standard) {
        let model = LyricAppModel(storageURL: storageURL, defaults: defaults)
        self.model = model
        super.init()
        presentationSubscription = model.$presentation.compactMap { $0 }.sink { [weak self] page in
            self?.openManagementPage?(page)
        }
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(releaseRequested), name: LyricHandoff.request, object: nil)
    }

    @discardableResult public func activate(takingOverStandalone: Bool = true) async -> Bool {
        guard !transitioning else { return false }
        if isPresented && model.ownsSession { return true }
        transitioning = true
        defer { transitioning = false }
        var acquired = await model.start()
        if !acquired && takingOverStandalone {
            LyricHandoff.requestRelease(of: .standalone)
            // A missed notification, crashed owner or already released lease is resolved by flock.
            for _ in 0..<40 where !acquired {
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return false }
                acquired = await model.start()
            }
        }
        guard acquired else { await model.stop(); return false }
        isPresented = true; model.isVisible = false
        return true
    }

    @discardableResult public func deactivate() async -> Bool {
        guard !transitioning else { return false }
        guard isPresented || model.ownsSession else { return true }
        transitioning = true
        defer { transitioning = false }
        isPresented = false; model.isVisible = false
        model.presentation = nil
        // Hosts can confirm their own view transaction; a host window itself stays visible.
        if let hostSurfaceDidWithdraw {
            guard await hostSurfaceDidWithdraw() else { return false }
        } else {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(32))
        }
        await model.stop()
        LyricHandoff.announceRelease(from: .host)
        return true
    }
    public var view: some View { NearpaneLyricsView(module: self) }

    public func managementView(for page: LyricAuxiliaryPage) -> some View {
        LyricAuxiliaryView(model: model, page: page, close: { [weak self] in
            self?.model.presentation = nil
            self?.openManagementPage?(.settings)
        })
    }

    #if DEBUG
    /// Explicit fixture for native rendering tests; does not claim a real media session.
    public func installVerificationSnapshot(_ snapshot: PlaybackSnapshot, document: LyricDomain.Document? = nil) {
        precondition(!transitioning && !model.ownsSession)
        model.installVerificationSnapshot(snapshot, document: document)
        isPresented = snapshot.selection != nil
    }
    #endif

    @objc private func releaseRequested(_ notification: Notification) {
        guard let requestID = LyricHandoff.requestID(from: notification, targeting: .host), model.ownsSession else { return }
        Task { @MainActor [weak self] in
            let succeeded = await self?.deactivate() ?? false
            LyricHandoff.acknowledge(requestID, succeeded: succeeded)
        }
    }
}

public struct NearpaneLyricsView: View {
    @ObservedObject private var module: NearpaneLyricsModule
    public init(module: NearpaneLyricsModule) { self.module = module }
    public var body: some View {
        Group {
            if module.isPresented {
                // Host owns visibility; an idle or temporarily withdrawn card must not stop the observer.
                LyricPanelView(model: module.model)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}
