import NearpaneCore
import SwiftUI

struct ClockDetails: View {
    let host: HostSession
    private static let regions = Dictionary(grouping: TimeZone.knownTimeZoneIdentifiers) {
        String($0.split(separator: "/").first ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TimelineView(.everyMinute) { tick in
                VStack(alignment: .leading, spacing: 6) {
                    Text("本地时间").font(.caption).foregroundStyle(.secondary)
                    Text(LocalClock.time(tick.date)).font(.title3).monospacedDigit().accessibilityIdentifier("clock-local-time")
                    if let id = host.configuration.clockTimeZoneID, let zone = TimeZone(identifier: id) {
                        Text(id.replacingOccurrences(of: "_", with: " ")).font(.caption).foregroundStyle(.secondary)
                        Text(LocalClock.time(tick.date, zone: zone)).font(.callout).monospacedDigit()
                    }
                }
            }
            Menu("时区") {
                Button("仅本地时间") { host.setClockTimeZone(nil) }
                ForEach(Self.regions.keys.sorted(), id: \.self) { region in
                    Menu(region) {
                        ForEach(Self.regions[region] ?? [], id: \.self) { id in
                            Button(id.replacingOccurrences(of: "_", with: " ")) { host.setClockTimeZone(id) }
                        }
                    }
                }
            }
            .menuStyle(.borderlessButton).fixedSize().accessibilityLabel("额外时区")
            if host.clockNeedsAttention {
                Text("额外时区未能读取。原设置已保留，可从「时区」重新选择。").font(.caption)
            }
            if host.configurationSaveFailed { Text("设置未能保存。").font(.caption) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
