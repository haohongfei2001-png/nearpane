import AppKit
import Security
import CReadOnlySpaces
import NearpaneCore

struct ActionFailure: Error { let text: String; init(_ text: String) { self.text = text } }

struct ActionInventory: Equatable {
    struct Space: Equatable {
        let id: String
        let uuid: UUID?
        let kind: NativeSpaceKind?
    }
    struct Display: Equatable {
        let number: CGDirectDisplayID
        let bounds: CGRect
        let current: String
        let spaces: [Space]
    }
    let displays: [UUID: Display]
    let session: Int
    var currents: [String: String] {
        Dictionary(uniqueKeysWithValues: displays.map { ($0.key.uuidString, $0.value.current) })
    }

    static func id(_ value: Any?) -> String? {
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(),
              let id = UInt64(n.stringValue), id > 0 else { return nil }
        return String(id)
    }

    static func read() throws -> Self {
        var securitySession: SecuritySessionId = 0
        guard SessionGetInfo(callerSecuritySession, &securitySession, nil) == errSecSuccess,
              let session = CGSessionCopyCurrentDictionary() as? [String: Any],
              session[kCGSessionOnConsoleKey as String] as? Bool == true,
              session["CGSSessionScreenIsLocked"] as? Bool != true,
              session[kCGSessionLoginDoneKey as String] as? Bool == true,
              session[kCGSessionUserIDKey as String] as? UInt32 == getuid(),
              let raw = NPReadInventory() as? [[String: Any]], !raw.isEmpty, raw.count <= 32
        else { throw ActionFailure("当前登录会话或空间信息不可用。") }
        var ids = Set<String>(), uuids = Set<UUID>(), displays: [UUID: Display] = [:]
        var count: UInt32 = 0
        var numbers = [CGDirectDisplayID](repeating: 0, count: 32)
        guard CGGetActiveDisplayList(32, &numbers, &count) == .success, count == raw.count,
              count == 1 || NSScreen.screensHaveSeparateSpaces else { throw ActionFailure("当前显示器无法独立路由。") }
        for row in raw {
            guard let name = row["Display Identifier"] as? String, let uuid = UUID(uuidString: name), displays[uuid] == nil,
                  let number = numbers.prefix(Int(count)).first(where: { id in
                      guard let value = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { return false }
                      return UUID(uuidString: CFUUIDCreateString(nil, value) as String) == uuid
                  }), CGDisplayIsInMirrorSet(number) == 0,
                  let current = id((row["Current Space"] as? [String: Any])?["id64"]),
                  let entries = row["Spaces"] as? [[String: Any]], !entries.isEmpty, entries.count <= 256
            else { throw ActionFailure("显示器与空间的对应关系不唯一。") }
            let spaces = try entries.map { row -> Space in
                guard let id = id(row["id64"]), ids.insert(id).inserted,
                      let type = row["type"] as? NSNumber, CFGetTypeID(type) != CFBooleanGetTypeID(),
                      let typeCode = Int(type.stringValue)
                else { throw ActionFailure("空间记录存在歧义。") }
                let uuid = (row["uuid"] as? String).flatMap(UUID.init(uuidString:))
                if let uuid, !uuids.insert(uuid).inserted { throw ActionFailure("空间身份重复。") }
                return .init(id: id, uuid: uuid, kind: NativeSpaceKind(rawValue: typeCode))
            }
            guard spaces.contains(where: { $0.id == current }) else { throw ActionFailure("当前空间已改变。") }
            displays[uuid] = .init(number: number, bounds: CGDisplayBounds(number), current: current, spaces: spaces)
        }
        return .init(displays: displays, session: Int(securitySession))
    }

    func route(_ request: NativeSpaceCommand) throws -> (Display, Int, Int) {
        guard let id = UUID(uuidString: request.display), let display = displays[id],
              let fromUUID = request.sourceUUID, let toUUID = request.targetUUID,
              request.action == .select || (request.sourceKind == .ordinary && request.targetKind == .ordinary),
              let from = display.spaces.firstIndex(where: { $0.kind == request.sourceKind && $0.id == request.source && $0.uuid == fromUUID }),
              let to = display.spaces.firstIndex(where: { $0.kind == request.targetKind && $0.id == request.target && $0.uuid == toUUID })
        else { throw ActionFailure("来源或目标桌面的身份已失效。") }
        if request.action == .select, display.current != request.source {
            throw ActionFailure("当前桌面已经改变。")
        }
        if request.action == .select && abs(from - to) > 1 {
            throw ActionFailure("当前版本仅验证相邻桌面。请使用系统桌面控制。")
        }
        return (display, from, to)
    }

    /// A later observation may remain at the origin or advance to the adjacent target.
    func transition(from before: Self, request: NativeSpaceCommand, previous: Int) throws -> Int {
        let (_, source, target) = try before.route(request)
        guard let uuid = UUID(uuidString: request.display), let view = displays[uuid],
              let index = view.spaces.firstIndex(where: { $0.id == view.current }),
              (min(previous, target)...max(previous, target)).contains(index),
              (min(source, target)...max(source, target)).contains(index)
        else { throw ActionFailure("切换偏离原始目标。") }
        var expected = before.currents
        expected[uuid.uuidString] = view.current
        guard agrees(with: before, expected: expected) else { throw ActionFailure("过渡期间其他桌面或显示器发生改变。") }
        return index
    }

    func agrees(with before: Self, expected: [String: String]) -> Bool {
        session == before.session && displays.keys == before.displays.keys && currents == expected &&
        displays.allSatisfy { key, value in
            guard let old = before.displays[key] else { return false }
            return old.number == value.number && old.bounds == value.bounds && old.spaces == value.spaces
        }
    }
}
