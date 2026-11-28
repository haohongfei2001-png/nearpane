import Foundation

/// The view owns the visible minute schedule. A resident clock owns no timer,
/// observer, network connection or system permission.
@MainActor
final class LocalClockModule: HostModule {
    func start() {}
    func stop() {}
    func suspend() {}
    func resume() {}
    func perform(_ action: ModuleAction) {}
    func snapshot() -> ModuleProjection { .init(message: LocalClock.time(.now)) }
}

public enum LocalClock {
    public static func time(_ date: Date, zone: TimeZone = .autoupdatingCurrent,
                            locale: Locale = .autoupdatingCurrent) -> String {
        date.formatted(Date.FormatStyle(date: .omitted, time: .shortened, locale: locale, timeZone: zone))
    }
}
