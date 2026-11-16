/// Presentation and observation depend on both the latest system reading and
/// the independent sleep, lock and login-session notifications. In particular a
/// lit display is not evidence that the login session is safe to present in.
public struct DesktopSessionAvailability: Equatable, Sendable {
    public enum Event: Sendable {
        case sample, willSleep, didWake, screensSleep, screensWake, resigned, becameActive, locked, unlocked
    }

    public init() {}
    private var sleeping = false, screensSleeping = false, resigned = false, lockAnnounced = false
    private var hasAwakeDisplay = false, consoleActive = false, consoleLocked = true

    public var desktopAsleep: Bool { sleeping || screensSleeping || !hasAwakeDisplay }
    public var sessionRestricted: Bool { resigned || lockAnnounced || !consoleActive || consoleLocked }
    public var unavailable: Bool { desktopAsleep || sessionRestricted }

    public mutating func observe(_ event: Event, hasAwakeDisplay: Bool, consoleActive: Bool, consoleLocked: Bool) {
        switch event {
        case .willSleep: sleeping = true
        case .didWake: sleeping = false
        case .screensSleep: screensSleeping = true
        case .screensWake: screensSleeping = false
        case .resigned: resigned = true
        case .becameActive: resigned = false
        case .locked: lockAnnounced = true
        case .unlocked: lockAnnounced = false
        case .sample: break
        }
        self.hasAwakeDisplay = hasAwakeDisplay
        self.consoleActive = consoleActive
        self.consoleLocked = consoleLocked
    }
}
