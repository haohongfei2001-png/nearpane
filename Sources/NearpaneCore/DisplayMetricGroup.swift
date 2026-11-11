// Size overrides have a single owner. Restoring one group's factory values must
// not discard placement, visibility, another module, or another screen's settings.
public enum DisplayMetricGroup: CaseIterable, Sendable {
    case panel, voice, tray, spaces, modules
}

extension DisplayMetric {
    public var group: DisplayMetricGroup {
        switch self {
        case .panelWidth, .panelHeight, .reservedWidth, .sideInset, .topInset, .bottomInset, .verticalOffset, .sectionGap, .cornerRadius:
            .panel
        case .voiceHeight, .textHeight, .textPadding, .textSize, .lineGap, .voiceButtonWidth, .voiceButtonHeight, .copySize, .buttonGap, .waveformSize:
            .voice
        case .trayHeight, .cellWidth, .cellHeight, .columnGap, .rowGap, .trayPadding, .trayMenuHeight, .trayButtonSize:
            .tray
        case .spacesHeight, .spaceRowHeight, .spaceRowGap, .desktopWidth, .desktopHeight, .spacePadding, .scrollHeight, .borderWidth, .labelSize:
            .spaces
        case .iconSize, .hitSize, .railHeight, .railButtonWidth, .modulePadding, .moduleHeight:
            .modules
        }
    }
}

extension DisplaySettings {
    public func restoringSizes(group: DisplayMetricGroup?) -> Self {
        var updated = self
        updated.measures = measures.filter { group != nil && $0.key.group != group }
        return updated
    }
}
