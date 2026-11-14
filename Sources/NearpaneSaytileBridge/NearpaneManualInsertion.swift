import AppKit
import ApplicationServices

/// Check cheap foreground, ownership and document identity *before* Saytile
/// inspects the field or hashes any web accessibility context.
@MainActor final class GestureFieldSelection {
    struct Document {
        let area: AXUIElement?
        let address: String?

        func matches(_ other: Document) -> Bool {
            guard address == other.address else { return false }
            switch (area, other.area) {
            case let (left?, right?): return CFEqual(left, right)
            case (nil, nil): return true
            default: return false
            }
        }
    }
    private var origin: (field: AXInputSelection, document: Document)?
    private let frontPID: @MainActor () -> pid_t?
    private let focus: @MainActor () throws -> AXInputSelection
    private let isLive: @MainActor (NSRunningApplication) -> Bool
    private let isOwned: @MainActor (AXInputSelection) -> Bool
    private let document: @MainActor (AXInputSelection) throws -> Document

    init(frontPID: @escaping @MainActor () -> pid_t? = { NSWorkspace.shared.frontmostApplication?.processIdentifier },
         focus: @escaping @MainActor () throws -> AXInputSelection = AXInputAccess.frontmostSelection,
         isLive: @escaping @MainActor (NSRunningApplication) -> Bool = { !$0.isTerminated },
         isOwned: @escaping @MainActor (AXInputSelection) -> Bool = GestureFieldSelection.belongsToWindow,
         document: @escaping @MainActor (AXInputSelection) throws -> Document = GestureFieldSelection.readDocument) {
        self.frontPID = frontPID
        self.focus = focus
        self.isLive = isLive
        self.isOwned = isOwned
        self.document = document
    }

    func selected() throws -> AXInputSelection {
        guard let pid = frontPID(), origin == nil || origin?.field.application.processIdentifier == pid else {
            throw NativeInputError.targetChanged
        }
        let field = try focus()
        guard field.application.processIdentifier == pid else { throw NativeInputError.targetChanged }
        if let original = origin?.field {
            guard isLive(original.application), original.application == field.application,
                  CFEqual(original.root, field.root), CFEqual(original.window, field.window),
                  CFEqual(original.element, field.element) else { throw NativeInputError.targetChanged }
        }
        guard isOwned(field) else { throw NativeInputError.unsupported }
        let current = try document(field)
        guard frontPID() == pid, origin?.document.matches(current) != false else {
            throw NativeInputError.targetChanged
        }
        if origin == nil { origin = (field, current) }
        return field
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        AXUIElementSetMessagingTimeout(element, 0.12)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }
    private static func element(_ owner: AXUIElement, _ name: String) -> AXUIElement? {
        guard let value = attribute(owner, name), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeDowncast(value, to: AXUIElement.self)
    }
    private static func belongsToWindow(_ field: AXInputSelection) -> Bool {
        let expected = field.application.processIdentifier
        for ref in [field.window, field.element] {
            var pid: pid_t = 0
            guard AXUIElementGetPid(ref, &pid) == .success, pid == expected else { return false }
        }
        guard let owner = element(field.element, kAXWindowAttribute) else { return false }
        return CFEqual(owner, field.window)
    }
    private static func readDocument(_ field: AXInputSelection) throws -> Document {
        func address(_ element: AXUIElement, _ name: String) -> String? {
            let value = attribute(element, name)
            return (value as? String) ?? (value as? URL)?.absoluteString
        }
        let windowDocument = address(field.window, kAXDocumentAttribute)
        var node = field.element
        for _ in 0..<24 {
            if CFEqual(node, field.window) {
                guard !InputSafetyPolicy.isBrowser(applicationID: field.application.bundleIdentifier ?? "") else {
                    throw NativeInputError.unobservablePage
                }
                return Document(area: nil, address: windowDocument)
            }
            guard let role = attribute(node, kAXRoleAttribute) as? String else { break }
            if role == "AXWebArea" {
                guard let url = address(node, kAXURLAttribute) ?? address(node, kAXDocumentAttribute) ?? windowDocument,
                      !url.isEmpty else { throw NativeInputError.pageUnknown }
                return Document(area: node, address: url)
            }
            guard let parent = element(node, kAXParentAttribute) else { break }
            node = parent
        }
        throw NativeInputError.unsupported
    }
}

/// The context-menu gesture, not a later Task, chooses the field. Only a native
/// selected-text write is admitted; the domain's clipboard fallback is unreachable.
@MainActor private final class GestureInputAccess: InputAccess {
    let access: any InputAccess
    let target: InputTargetSnapshot
    let expired: () -> Bool
    var revoked = false
    private var dispatched = false
    private var domainObserving = false

    init(access: any InputAccess, expired: @escaping () -> Bool) throws {
        guard access.hasPermission else { throw NativeInputError.permission }
        self.access = access
        self.expired = expired
        target = try access.snapshot()
        try target.checked()
        guard target.canSetSelectedText, !target.isWeb || target.pageContextComplete else {
            throw NativeInputError.unsupported
        }
        let support = access.observe(target) { [weak self] _ in self?.revoked = true }
        guard support.focus, support.content, !target.isWeb || support.page else {
            access.stopObserving()
            throw NativeInputError.unsupported
        }
    }

    var hasPermission: Bool { !revoked && !expired() && access.hasPermission }
    func snapshot() throws -> InputTargetSnapshot {
        guard hasPermission else { throw NativeInputError.targetChanged }
        let current = try access.snapshot()
        guard current.sameTarget(as: target), current.canSetSelectedText,
              !current.isWeb || current.pageContextComplete, dispatched || current == target else {
            throw NativeInputError.targetChanged
        }
        return current
    }
    func dispatch(_ text: String, to expected: InputTargetSnapshot) throws -> Bool {
        guard try snapshot() == expected else { return false }
        do {
            let accepted = try access.dispatch(text, to: expected)
            if accepted { dispatched = true }
            return accepted
        } catch let timeout as AXTextWriteTimeout {
            // The single setter may already have moved the caret. Allow the
            // domain to settle this mutation by readback on the frozen target.
            dispatched = true
            throw timeout
        }
    }
    func verify(_ text: String, at before: InputTargetSnapshot) -> InputTargetSnapshot? {
        guard (try? snapshot()) != nil, let after = access.verify(text, at: before),
              (try? snapshot()) == after else { return nil }
        return after
    }
    func textWitness(at expected: InputTargetSnapshot) -> String? {
        guard (try? snapshot()) == expected else { return nil }
        return access.textWitness(at: expected)
    }
    func observe(_ expected: InputTargetSnapshot, onChange: @escaping @MainActor (InputTargetChange) -> Void) -> InputObservationSupport {
        domainObserving = true
        let support = access.observe(expected, onChange: onChange)
        if !support.focus || !support.content || (expected.isWeb && !support.page) { revoked = true }
        return support
    }
    func stopObserving() {
        // bindCurrentTarget clears the previous binding while persisting the new
        // one. Keep the gesture watcher across that await, until its replacement.
        if revoked || domainObserving { access.stopObserving() }
    }
    func matchesText(_ text: String, utf16Start: Int, at expected: InputTargetSnapshot) -> Bool? {
        guard hasPermission else { return nil }
        return access.matchesText(text, utf16Start: utf16Start, at: expected)
    }
}

@MainActor public final class NearpaneManualInsertion {
    private let guardAccess: GestureInputAccess
    private let coordinator: NativeInputCoordinator
    private let notifications: NotificationCenter?
    private var activation: NSObjectProtocol?

    /// Called synchronously by the one user gesture. No permission prompt, microphone,
    /// pasteboard inspection or fallback to a previously active app.
    public convenience init(store: SaytileStore) throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        let scope = GestureFieldSelection()
        try self.init(store: store, access: AXInputAccess(selectionProvider: scope.selected), expired: { .now >= deadline },
                      notifications: NSWorkspace.shared.notificationCenter)
    }

    init(store: SaytileStore, access: any InputAccess, expired: @escaping () -> Bool,
         notifications: NotificationCenter? = nil) throws {
        guardAccess = try GestureInputAccess(access: access, expired: expired)
        coordinator = NativeInputCoordinator(store: store, access: guardAccess)
        self.notifications = notifications
        let pid = guardAccess.target.processID
        activation = notifications?.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main) { [weak self] note in
                let newPID = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
                if newPID != pid { MainActor.assumeIsolated { self?.finish() } }
            }
    }

    public func bind() async throws {
        _ = try await coordinator.bindCurrentTarget(purpose: .manual)
    }
    public func insert(recording: UUID, revision: UUID) async -> NativeInputResult {
        await coordinator.insert(recordingID: recording, revisionID: revision)
    }
    public func finish() {
        guardAccess.revoked = true
        coordinator.invalidate()
        if let activation { notifications?.removeObserver(activation); self.activation = nil }
    }
}
