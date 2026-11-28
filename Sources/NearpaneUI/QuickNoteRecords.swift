import Foundation

extension CodingUserInfoKey {
    static let notebookMigrationDate = CodingUserInfoKey(rawValue: "nearpane.notebook.migrationDate")!
}

enum NotebookStorageError: LocalizedError {
    case unsupportedVersion(Int)
    case invalidContents

    var errorDescription: String? {
        switch self {
        case .unsupportedVersion:
            "这些记录由更新版本的 Nearpane 保存。请更新应用后打开；原有资料未被修改。"
        case .invalidContents:
            "记录资料不完整，原文件已保留。"
        }
    }
}

extension SidebarNotebook {
    enum RecordKind: String, Codable, CaseIterable { case note, task }

    enum Filter: String, CaseIterable {
        case all, notes, unfinished, completed

        var title: String {
            switch self {
            case .all: "全部记录"
            case .notes: "普通记录"
            case .unfinished: "未完成"
            case .completed: "已完成"
            }
        }
    }

    struct Record: Codable, Identifiable, Equatable {
        var id = UUID()
        var body: String
        var kind: RecordKind = .note
        var createdAt = Date()
        var updatedAt = Date()
        var isCompleted = false
        var completedAt: Date?

        var isEmpty: Bool { body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        var preview: String {
            body.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        }
    }

    /// One source of truth for the existing notebook domain. Legacy accessors adapt callers,
    /// while the file stores each record only once. Words and calculation retain their APIs.
    struct Contents: Codable, Equatable {
        var records: [Record] = []
        var activeRecordID: UUID?
        var calculation = ""
        var words: [Word] = []
        var migratedFromLegacy = false

        init() {}

        var memo: String {
            get { records.first(where: { $0.id == activeRecordID && $0.kind == .note })?.body ?? "" }
            set {
                let now = Date()
                if let index = records.firstIndex(where: { $0.id == activeRecordID && $0.kind == .note }) {
                    guard records[index].body != newValue else { return }
                    records[index].body = newValue
                    records[index].updatedAt = now
                } else if !newValue.isEmpty {
                    let record = Record(body: newValue, createdAt: now, updatedAt: now)
                    records.append(record)
                    activeRecordID = record.id
                }
            }
        }

        var tasks: [Entry] {
            get { records.filter { $0.kind == .task }.map { Entry(id: $0.id, title: $0.body, done: $0.isCompleted) } }
            set {
                let now = Date()
                let old = Dictionary(uniqueKeysWithValues: records.filter { $0.kind == .task }.map { ($0.id, $0) })
                let tasks = newValue.map { item -> Record in
                    var record = old[item.id] ?? Record(id: item.id, body: item.title, kind: .task,
                                                        createdAt: now, updatedAt: now)
                    if record.body != item.title || record.isCompleted != item.done {
                        record.updatedAt = now
                    }
                    record.body = item.title
                    if record.isCompleted != item.done {
                        record.completedAt = item.done ? now : nil
                    }
                    record.isCompleted = item.done
                    return record
                }
                records.removeAll { $0.kind == .task }
                records.append(contentsOf: tasks)
            }
        }

        private enum CodingKeys: String, CodingKey {
            case schemaVersion, records, activeRecordID, calculation, words, memo, tasks
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let version = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
            guard version == 1 || version == 2 else { throw NotebookStorageError.unsupportedVersion(version) }
            calculation = try container.decode(String.self, forKey: .calculation)
            words = try container.decode([Word].self, forKey: .words)
            if version == 2 {
                records = try container.decode([Record].self, forKey: .records)
                activeRecordID = try container.decodeIfPresent(UUID.self, forKey: .activeRecordID)
            } else {
                // Old records had no per-item dates. Their source file's modification date
                // is the migration baseline, not a claim about their original creation time.
                let migratedAt = decoder.userInfo[.notebookMigrationDate] as? Date ?? Date()
                let memo = try container.decode(String.self, forKey: .memo)
                let tasks = try container.decode([Entry].self, forKey: .tasks)
                if !memo.isEmpty {
                    let record = Record(body: memo, createdAt: migratedAt, updatedAt: migratedAt)
                    records.append(record)
                    activeRecordID = record.id
                }
                var used = Set(records.map(\.id))
                for task in tasks {
                    // Malformed legacy duplicates still retain every body. Preserve every
                    // original unique task ID; only a collision receives a fresh identity.
                    let id = used.insert(task.id).inserted ? task.id : UUID()
                    used.insert(id)
                    records.append(Record(id: id, body: task.title, kind: .task,
                                          createdAt: migratedAt, updatedAt: migratedAt,
                                          isCompleted: task.done, completedAt: task.done ? migratedAt : nil))
                }
                migratedFromLegacy = true
            }
            try validate()
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(2, forKey: .schemaVersion)
            try container.encode(records, forKey: .records)
            try container.encodeIfPresent(activeRecordID, forKey: .activeRecordID)
            try container.encode(calculation, forKey: .calculation)
            try container.encode(words, forKey: .words)
        }

        func validate() throws {
            guard Set(records.map(\.id)).count == records.count,
                  activeRecordID == nil || records.contains(where: { $0.id == activeRecordID && $0.kind == .note }),
                  records.allSatisfy({ record in
                      record.createdAt.timeIntervalSinceReferenceDate.isFinite &&
                      record.updatedAt.timeIntervalSinceReferenceDate.isFinite &&
                      (record.completedAt?.timeIntervalSinceReferenceDate.isFinite ?? true) &&
                      (record.kind == .task || (!record.isCompleted && record.completedAt == nil)) &&
                      (record.isCompleted == (record.completedAt != nil))
                  }) else { throw NotebookStorageError.invalidContents }
        }
    }

    var records: [Record] { contents.records }
    var activeRecordID: UUID? { contents.activeRecordID }
    var activeRecord: Record? { contents.records.first { $0.id == contents.activeRecordID && $0.kind == .note } }
    var unfinishedTasks: [Record] { contents.records.filter { $0.kind == .task && !$0.isCompleted } }

    func record(_ id: UUID) -> Record? { contents.records.first { $0.id == id } }

    func records(matching query: String = "", filter: Filter = .all) -> [Record] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return contents.records.filter { record in
            guard !record.isEmpty, term.isEmpty || record.body.localizedStandardContains(term) else { return false }
            switch filter {
            case .all: return true
            case .notes: return record.kind == .note
            case .unfinished: return record.kind == .task && !record.isCompleted
            case .completed: return record.kind == .task && record.isCompleted
            }
        }.sorted {
            if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
            if $0.createdAt != $1.createdAt { return $0.createdAt > $1.createdAt }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    /// Returning the existing empty draft makes accidental double clicks idempotent.
    @discardableResult func beginNote() -> UUID? {
        guard readable else { return nil }
        if let current = activeRecord, current.isEmpty { return current.id }
        let now = Date()
        let record = Record(body: "", createdAt: now, updatedAt: now)
        edit { contents in
            contents.records.append(record)
            contents.activeRecordID = record.id
        }
        return record.id
    }

    @discardableResult func updateActiveBody(_ body: String) -> Bool {
        guard readable else { return false }
        if let id = activeRecordID { return updateRecord(id, body: body) }
        guard !body.isEmpty else { return true }
        let now = Date(), id = UUID()
        return edit { contents in
            contents.records.append(Record(id: id, body: body, createdAt: now, updatedAt: now))
            contents.activeRecordID = id
        }
    }

    @discardableResult func updateRecord(_ id: UUID, body: String) -> Bool {
        guard let record = record(id) else { return false }
        guard record.body != body else { return !hasUnsavedChanges || retrySave() }
        return edit { contents in
            guard let index = contents.records.firstIndex(where: { $0.id == id }) else { return }
            contents.records[index].body = body
            contents.records[index].updatedAt = Date()
        }
    }

    @discardableResult func endNote() -> Bool {
        guard let active = activeRecord else { return readable }
        return edit { contents in
            if active.isEmpty { contents.records.removeAll { $0.id == active.id } }
            contents.activeRecordID = nil
        }
    }

    @discardableResult func focusRecord(_ id: UUID) -> Bool {
        guard record(id)?.kind == .note else { return false }
        return edit { contents in
            if let old = activeRecord, old.id != id, old.isEmpty {
                contents.records.removeAll { $0.id == old.id }
            }
            contents.activeRecordID = id
        }
    }

    /// An empty task is a durable draft, so typing never depends on pressing Return.
    @discardableResult func createTask(body: String) -> UUID? {
        guard readable else { return nil }
        if body.isEmpty, let blank = unfinishedTasks.first(where: \.isEmpty) { return blank.id }
        let now = Date(), id = UUID()
        edit { $0.records.append(Record(id: id, body: body, kind: .task, createdAt: now, updatedAt: now)) }
        return id
    }

    @discardableResult func convertRecord(_ id: UUID, to kind: RecordKind, activate: Bool = true) -> Bool {
        guard let original = record(id) else { return false }
        guard original.kind != kind else { return readable && (!hasUnsavedChanges || retrySave()) }
        return edit { contents in
            if kind == .note, activate, let old = activeRecord, old.id != id, old.isEmpty {
                contents.records.removeAll { $0.id == old.id }
            }
            guard let index = contents.records.firstIndex(where: { $0.id == id }) else { return }
            contents.records[index].kind = kind
            contents.records[index].updatedAt = Date()
            contents.records[index].isCompleted = false
            contents.records[index].completedAt = nil
            if kind == .task, contents.activeRecordID == id { contents.activeRecordID = nil }
            if kind == .note, activate { contents.activeRecordID = id }
        }
    }

    @discardableResult func setCompleted(_ id: UUID, completed: Bool) -> Bool {
        guard let original = record(id), original.kind == .task else { return false }
        guard original.isCompleted != completed else { return readable && (!hasUnsavedChanges || retrySave()) }
        return edit { contents in
            guard let index = contents.records.firstIndex(where: { $0.id == id }) else { return }
            let now = Date()
            contents.records[index].isCompleted = completed
            contents.records[index].completedAt = completed ? now : nil
            contents.records[index].updatedAt = now
        }
    }

    @discardableResult func deleteRecord(_ id: UUID) -> Bool {
        edit { contents in
            contents.records.removeAll { $0.id == id }
            if contents.activeRecordID == id { contents.activeRecordID = nil }
        }
    }
}
