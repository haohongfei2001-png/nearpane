#if DEBUG
import Foundation

/// Read-only observations and explicitly labelled seed content for the packaged,
/// executable-bound native acceptance profile. This is not a second notes store.
public struct QuickNotesVerificationRecord: Codable, Equatable, Sendable {
    public let id: UUID
    public let body: String
    public let kind: String
    public let createdAt: Date
    public let updatedAt: Date
    public let isCompleted: Bool
    public let completedAt: Date?
}

public struct QuickNotesVerificationState: Codable, Equatable, Sendable {
    public let records: [QuickNotesVerificationRecord]
    public let activeRecordID: UUID?
    public let readable: Bool
    public let hasUnsavedChanges: Bool
}

extension EmbeddedModules {
    @MainActor public var quickNotesVerificationState: QuickNotesVerificationState {
        Self.quickNotesState(notebook)
    }

    @MainActor public func quickNotesVerificationReload(directory: URL) -> QuickNotesVerificationState {
        Self.quickNotesState(SidebarNotebook(directory: directory))
    }

    /// Bulk overflow content is a fixture, never counted as native input coverage.
    @MainActor @discardableResult public func seedQuickNotesVerificationTask(_ body: String) -> UUID? {
        guard NativeVerificationAccessibility.isEnabled else { return nil }
        return notebook.createTask(body: body)
    }

    @MainActor private static func quickNotesState(_ source: SidebarNotebook) -> QuickNotesVerificationState {
        QuickNotesVerificationState(records: source.records.map {
            .init(id: $0.id, body: $0.body, kind: $0.kind.rawValue,
                  createdAt: $0.createdAt, updatedAt: $0.updatedAt,
                  isCompleted: $0.isCompleted, completedAt: $0.completedAt)
        }, activeRecordID: source.activeRecordID, readable: source.readable,
           hasUnsavedChanges: source.hasUnsavedChanges)
    }
}
#endif
