import Foundation
import WindowGeometryCore

public enum AdmissionWindowRole: String, Codable, Sendable { case ordinary, ineligible, unknown }

/// Facts about exactly one selected CG number in one process incarnation. Unknowns remain explicit.
public struct AdmissionSample: Codable, Equatable, Sendable {
    public let pid: Int32, launch: UInt64?, number: UInt32, bundle: String?, uptime: Double
    public var element: UUID?, axNumber: UInt32?, cgFrame: SurfaceRect?, axFrame: SurfaceRect?
    public var onScreen: Bool?, layer: Int?, minimized: Bool?, fullscreen: Bool?, display: String?
    public var minimum: SurfaceRect?, positionSettable: Bool?, sizeSettable: Bool?, editGeneration: String?
    /// Incarnation of a continuously registered system observer. No target-app edit token is inferred.
    public var liveObservation: UUID?
    public var usesWitnessedSize: Bool?
    public var stageManager: Bool?, permission = false, recoveryVerified = false
    /// The identity selected in Settings was positively witnessed again in both samples.
    public var selectionContinuity = false
    public var role: AdmissionWindowRole = .unknown

    public init(pid: Int32, launch: UInt64?, number: UInt32, bundle: String?, uptime: Double) {
        self.pid = pid
        self.launch = launch
        self.number = number
        self.bundle = bundle
        self.uptime = uptime
    }

    public var id: ManagedWindowID? {
        guard pid > 0, number > 0, let launch, launch > 0, let element, axNumber == number else { return nil }
        return ManagedWindowID(pid: pid, launch: launch, number: number, element: element)
    }

    fileprivate var presentation: WindowPresentationGeometry {
        guard let cgFrame else { return .unconfirmed }
        return .init(cg: cgFrame.geometry, ax: axFrame?.geometry, onScreen: onScreen)
    }
}

public struct AdmissionPair: Equatable, Codable, Sendable {
    public let first, second: AdmissionSample
    public init(first: AdmissionSample, second: AdmissionSample) { self.first = first; self.second = second }
}

public struct AdmissionContext: Equatable, Sendable {
    public var display: String, screen: SurfaceRect, usable: SurfaceRect, primary: Bool
    public var settings: DisplaySettings, edge: SurfaceEdge, preferences: WorkspacePreferences
    public var recoveryClear: Bool, exclusive: Bool?, ratio: Double, swapped: Bool, pairCustomized: Bool
    public var hypothetical = false
    /// When available, these must come from the exact cohort's verified management record.
    public var savedLayout: ManagedWindowTiler?, originalFrames: [ManagedWindowID: SurfaceRect] = [:]

    public init(display: String, screen: SurfaceRect, usable: SurfaceRect, primary: Bool, settings: DisplaySettings,
                edge: SurfaceEdge, preferences: WorkspacePreferences, recoveryClear: Bool, exclusive: Bool?,
                ratio: Double = 0.5, swapped: Bool = false, pairCustomized: Bool = false) {
        self.display = display; self.screen = screen; self.usable = usable; self.primary = primary
        self.settings = settings; self.edge = edge; self.preferences = preferences
        self.recoveryClear = recoveryClear; self.exclusive = exclusive
        self.ratio = ratio; self.swapped = swapped; self.pairCustomized = pairCustomized
    }
}

public enum AdmissionStatus: String, Codable, Sendable { case reviewable, insufficient, ineligible }

public enum AdmissionReason: String, Codable, Sendable {
    case selection, stale, identity, selectionContinuity, duplicate, permission, excluded, role, unknownRole
    case geometry, visibility, transition, display, minimumUnknown, minimumConflict
    case lockedFrame, unknownFrameRights, editGeneration, recovery, pendingJournal
    case competition, unknownOwner, layout, hypothetical

    public var text: String {
        switch self {
        case .selection: "先选择要预演的窗口"
        case .stale: "缺少两次新鲜且间隔足够的窗口读数"
        case .identity: "无法唯一对应进程代际、窗口号和 AX 对象"
        case .selectionContinuity: "无法从初选持续核对同一窗口，仅取得当前编号的读数"
        case .duplicate: "所选窗口号或对象身份出现重复"
        case .permission: "缺少现有辅助功能读取权限"
        case .excluded: "此应用或窗口已被排除"
        case .role: "菜单、对话框、全屏、最小化或非普通窗口不在范围内"
        case .unknownRole: "普通窗口类型及状态尚未核实"
        case .geometry: "AX 与 CG 呈现几何不一致或未知"
        case .visibility: "无法确认窗口当前在屏"
        case .transition: "两次观测之间窗口或系统呈现状态发生变化"
        case .display: "无法将窗口完整对应到同一显示器的可用区域"
        case .minimumUnknown: "缺少此窗口的可靠最小尺寸"
        case .minimumConflict: "当前或预计的窗口尺寸小于已知下限"
        case .lockedFrame: "此窗口不支持移动或调整大小"
        case .unknownFrameRights: "窗口的位置或大小写入能力未知"
        case .editGeneration: "缺少本窗口的稳定编辑代际"
        case .recovery: "无法核对恢复基线或本窗口的恢复能力"
        case .pendingJournal: "恢复记录待处理或状态未知"
        case .competition: "窗口管理器所有权存在冲突"
        case .unknownOwner: "尚未核对窗口管理器所有权"
        case .layout: "布局的槽位、比例或工作区域无效"
        case .hypothetical: "当前为替代工作区配置，仅供布局比较"
        }
    }

    fileprivate var definite: Bool {
        switch self {
        case .excluded, .role, .lockedFrame, .minimumConflict: true
        default: false
        }
    }
}

public struct AdmissionPreviewResult: Sendable {
    public fileprivate(set) var reasons: [AdmissionReason] = [], notes: [String] = []
    public fileprivate(set) var current: [ManagedWindowID: SurfaceRect] = [:]
    public fileprivate(set) var proposed: [ManagedWindowID: SurfaceRect] = [:]
    public fileprivate(set) var exitFrames: [ManagedWindowID: SurfaceRect] = [:]
    public fileprivate(set) var workRect: SurfaceRect?, validUntil: Double?
    public fileprivate(set) var preparation: PreparedWindowAdmission?
    public var status: AdmissionStatus {
        if reasons.contains(where: \.definite) { return .ineligible }
        return preparation == nil ? .insufficient : .reviewable
    }

    fileprivate mutating func reject(_ reason: AdmissionReason) {
        if !reasons.contains(reason) { reasons.append(reason) }
    }
}

/// An in-memory description for a possible future consent sheet. It has no executor, write lease or disk format.
public struct PreparedWindowAdmission: Sendable {
    public let members: [ManagedWindowID], validUntil: Double
    fileprivate let samples: [AdmissionSample], context: AdmissionContext

    /// A new review must still bind the same selected objects, geometry, edits, permissions and scope.
    /// Even success here only permits asking the user. The actual fixture writer keeps its independent checks.
    public func matchesFreshReview(_ pairs: [AdmissionPair], context: AdmissionContext, uptime: Double) -> Bool {
        guard uptime <= validUntil, context == self.context,
              let next = WindowAdmissionPreview.evaluate(pairs, context: context, uptime: uptime).preparation,
              next.members == members, samples.count == pairs.count else { return false }
        return zip(samples, pairs).allSatisfy { prior, pair in
            pair.first.uptime >= prior.uptime && WindowAdmissionPreview.sameFacts(prior, pair.second)
        }
    }
}

public enum WindowAdmissionPreview {
    private static let witnessedSizeNote = "应用未报告最小尺寸，仅允许在已见证的初始宽高范围以上调整。"
    private static let maxAge = 3.0
    private static let sampleInterval = 0.08

    /// Compare all input facts other than their sampling times. P4.8 requires exact frame agreement.
    fileprivate static func sameFacts(_ a: AdmissionSample, _ b: AdmissionSample) -> Bool {
        a.pid == b.pid && a.launch == b.launch && a.bundle == b.bundle && a.number == b.number
            && a.element == b.element && a.axNumber == b.axNumber && a.cgFrame == b.cgFrame && a.axFrame == b.axFrame
            && a.display == b.display && a.stageManager == b.stageManager && a.onScreen == b.onScreen
            && a.role == b.role && a.layer == b.layer && a.minimized == b.minimized && a.fullscreen == b.fullscreen
            && a.liveObservation == b.liveObservation && a.usesWitnessedSize == b.usesWitnessedSize
            && a.minimum == b.minimum && a.editGeneration == b.editGeneration && a.permission == b.permission
            && a.recoveryVerified == b.recoveryVerified && a.positionSettable == b.positionSettable && a.sizeSettable == b.sizeSettable
            && a.selectionContinuity == b.selectionContinuity
    }

    public static func evaluate(_ pairs: [AdmissionPair], context: AdmissionContext, uptime: Double) -> AdmissionPreviewResult {
        var result = AdmissionPreviewResult()
        guard !pairs.isEmpty else { result.reject(.selection); return result }
        // WindowServer numbers are global in a snapshot. An AX object must not identify two
        // numbers within one process. Never display one side of an ambiguous selection as current.
        guard Set(pairs.map(\.second.number)).count == pairs.count else {
            result.reject(.duplicate); return result
        }
        for process in Dictionary(grouping: pairs, by: \.second.pid).values {
            let elements = process.compactMap(\.second.element)
            guard Set(elements).count == elements.count else { result.reject(.duplicate); return result }
            guard Set(process.map(\.second.launch)).count == 1, Set(process.map(\.second.bundle)).count == 1 else {
                result.reject(.identity); return result
            }
        }
        if !context.recoveryClear { result.reject(.pendingJournal) }
        if context.exclusive != true { result.reject(context.exclusive == false ? .competition : .unknownOwner) }
        if context.hypothetical { result.reject(.hypothetical) }
        do {
            result.workRect = try DesktopWorkArea(display: context.display, screen: context.screen, usable: context.usable,
                primary: context.primary, settings: context.settings, fallbackEdge: context.edge).ordinary
        } catch { result.reject(.layout) }

        var members: [ManagedMember] = []
        for pair in pairs {
            let a = pair.first, b = pair.second
            let fresh = a.uptime.isFinite && b.uptime.isFinite && uptime.isFinite && a.uptime >= 0
                && b.uptime >= a.uptime + sampleInterval && uptime >= b.uptime && uptime - a.uptime <= maxAge
            if !fresh { result.reject(.stale) }
            let stable = sameFacts(a,b)
            if !stable { result.reject(.transition) }
            if !a.permission || !b.permission { result.reject(.permission) }
            if !a.selectionContinuity || !b.selectionContinuity { result.reject(.selectionContinuity) }
            if b.role == .ineligible || b.fullscreen == true || b.minimized == true || b.layer.map({ $0 != 0 }) == true {
                result.reject(.role)
            } else if b.role != .ordinary || b.fullscreen == nil || b.minimized == nil || b.layer == nil {
                result.reject(.unknownRole)
            }
            if b.onScreen != true { result.reject(.visibility) }
            if b.presentation != .confirmed || a.presentation != .confirmed { result.reject(.geometry) }
            if b.positionSettable == false || b.sizeSettable == false { result.reject(.lockedFrame) }
            else if b.positionSettable == nil || b.sizeSettable == nil { result.reject(.unknownFrameRights) }
            if b.editGeneration?.isEmpty != false && b.liveObservation == nil { result.reject(.editGeneration) }
            if !b.recoveryVerified { result.reject(.recovery) }
            if b.usesWitnessedSize == true && !result.notes.contains(witnessedSizeNote) {
                result.notes.append(witnessedSizeNote)
            }
            guard let id = b.id, a.id == id, let bundle = b.bundle, !bundle.isEmpty else {
                result.reject(.identity); continue
            }
            do {
                if try context.preferences.excluded(id, bundle: bundle) { result.reject(.excluded) }
            } catch { result.reject(.identity) }

            guard let frame = b.cgFrame, b.display == context.display, !context.display.isEmpty,
                  context.usable.geometry.isValid && context.usable.geometry.intersection(frame.geometry) == frame.geometry
            else { result.reject(.display); continue }
            guard stable && fresh && b.presentation == .confirmed && b.permission else { continue }
            result.current[id] = frame
            guard let minimum = b.minimum, minimum.geometry.isValid else { result.reject(.minimumUnknown); continue }
            guard frame.width >= minimum.width && frame.height >= minimum.height else {
                result.reject(.minimumConflict); continue
            }
            members.append(ManagedMember(id, minimumWidth: minimum.width, minimumHeight: minimum.height,
                                         canResize: b.positionSettable == true && b.sizeSettable == true))
        }
        result.validUntil = pairs.map(\.first.uptime).min().map { $0 + maxAge }
        guard members.count == pairs.count, let work = result.workRect else { return result }
        guard !result.reasons.contains(where: { $0.definite || [.identity,.transition,.geometry,.stale,.display,.permission,.unknownRole,.visibility,.unknownFrameRights].contains($0) }) else { return result }

        do {
            let layout = try layout(members, in: work, context: context)
            result.proposed = try layout.frames(in: work)
            if context.preferences.newWindow == .newWorkspace {
                result.notes.append("新窗默认独立工作区。当前无法创建系统空间，此处预演同屏分割。")
            }
            if members.count > 8 {
                result.notes.append(context.preferences.overflow == .newAboveEight
                    ? "已超过八窗。新建空间能力关闭，本次按继续分割估算。"
                    : "已超过八窗，按当前设置继续分割。")
            }
            if result.reasons.isEmpty || result.reasons == [.hypothetical] {
                var restoration = result.current
                for member in members where context.savedLayout?.members.contains(where: { $0.id == member.id }) == true {
                    guard let original = context.originalFrames[member.id], original.geometry.isValid,
                          original.geometry.intersection(context.usable.geometry) == original.geometry,
                          original.width >= member.minimumWidth, original.height >= member.minimumHeight else {
                        result.reject(.recovery); return result
                    }
                    restoration[member.id] = original
                }
                if layout.userAdjusted {
                    result.exitFrames = try layout.frames(in: context.usable)
                    result.notes.append("明确退出时，预计将所选比例与槽位映射到完整工作区域。")
                } else {
                    result.exitFrames = restoration
                    result.notes.append("明确退出时，预计恢复至首次接管前的位置。")
                }
            }
            if !result.exitFrames.isEmpty {
                result.notes.append("暂停会保留当前布局。异常恢复须重新核对原窗口、编辑代际与落盘事务。")
            }
            if result.reasons.isEmpty, let until = result.validUntil {
                result.preparation = .init(members: members.map(\.id), validUntil: until, samples: pairs.map(\.second), context: context)
            }
        } catch WorkspaceFailure.minimumSize { result.reject(.minimumConflict) }
        catch { result.reject(.layout) }
        return result
    }

    private static func layout(_ members: [ManagedMember], in work: SurfaceRect, context: AdmissionContext) throws -> ManagedWindowTiler {
        guard context.ratio.isFinite && (0.2...0.8).contains(context.ratio) else { throw WorkspaceFailure.invalidLayout }
        var layout = context.savedLayout ?? .init(workspace: nil)
        let selected = Set(members.map(\.id))
        for m in layout.members where !selected.contains(m.id) { layout = try layout.removing(m.id, in: work) }
        for m in members where !layout.members.contains(where: { $0.id == m.id }) { layout = try layout.adding(m, in: work) }
        // Applying a saved pair preference to the exact two selected objects keeps their join order stable.
        if members.count == 2 && (context.pairCustomized || context.ratio != 0.5 || context.swapped) {
            layout = try ManagedWindowTiler(workspace: layout.workspace).adding(members[0], in: work).adding(members[1], in: work)
            layout = try layout.adjusting(path: [], axis: .columns, ratio: context.ratio, in: work)
            if context.swapped { layout = try layout.swapping(members[0].id, members[1].id, in: work) }
        }
        return try layout.refreshingRequirements(members, in: work)
    }
}
