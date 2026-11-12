import AppKit
import NearpaneCore
import Testing
@testable import NearpaneUI

@MainActor private final class FieldWithInputMethod: PanelDimensionTextField {
    let input = NSTextView(frame: .zero)
    override func currentEditor() -> NSText? { input }
}

@MainActor struct PanelSizeDraftTests {
    @Test func layoutRefreshAndAXLeaveMarkedTextWithTheInputMethodUntilCommit() {
        let field = FieldWithInputMethod(frame: .zero)
        field.isEditable = true
        var edits: [String] = []
        field.edited = { edits.append($0) }
        field.display("10")
        let entireField = NSRange(location: 0, length: 2)
        field.input.setMarkedText("十", selectedRange: NSRange(location: 1, length: 0), replacementRange: entireField)
        let changed = Notification(name: NSControl.textDidChangeNotification, object: field)
        field.controlTextDidChange(changed)
        field.display("10")
        field.setAccessibilityValue("80")
        #expect(field.input.hasMarkedText() && field.input.string == "十" && edits.isEmpty)
        field.input.insertText("12", replacementRange: field.input.markedRange())
        field.controlTextDidChange(changed)
        #expect(!field.input.hasMarkedText() && edits == ["12"])
        field.setAccessibilityValue("12.5")
        #expect(field.input.string == "12.5" && edits == ["12", "12.5"])
    }

    @Test func successiveNativeFieldEditsReachOneDraftBeforeFocusChangesOrApply() throws {
        let saved = DisplaySettings()
        let session = PanelSizeEditing(saved)
        let width = PanelDimensionTextField(frame: .zero)
        let height = PanelDimensionTextField(frame: .zero)
        let widthValue = session.dimension(\.width), heightValue = session.dimension(\.height)
        width.edited = { widthValue.wrappedValue.enter($0) }
        height.edited = { heightValue.wrappedValue.enter($0) }
        width.setAccessibilityValue("55")
        height.setAccessibilityValue("62.5")
        #expect(width.stringValue == "55" && height.stringValue == "62.5")
        let rect = SurfaceRect(width: 800, height: 1280)
        let screen = ScreenGeometry(id: "secondary", frame: rect, visibleFrame: rect)
        let applied = try #require(session.draft.settings(over: saved, on: screen))
        #expect(applied.measures[.panelWidth] == Measure(55, .percent))
        #expect(applied.measures[.panelHeight] == Measure(62.5, .percent))
        #expect(saved.measures.isEmpty)
        // A subsequent typed edit uses the same draft and retains the other field.
        width.stringValue = "18.125"
        width.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: width))
        #expect(session.draft.width.measure == Measure(18.125, .percent))
        #expect(session.draft.height.measure == Measure(62.5, .percent))
    }

    @Test func liveDraftAndResetOnlyCommitTheChosenDisplayOnApply() async throws {
        let store = MemoryConfigurationStore()
        let host = HostSession(store: store)
        await host.start()
        defer { host.stop() }
        let screenFrame = SurfaceRect(x: -800, width: 800, height: 1280)
        let screen = ScreenGeometry(id: "secondary", frame: screenFrame, visibleFrame: screenFrame)
        var other = DisplaySettings()
        other.measures[.panelHeight] = Measure(73, .percent)
        host.setDisplaySettings(other, id: "main")
        var settings = DisplaySettings()
        settings.measures[.reservedWidth] = Measure(113)
        settings.measures[.textPadding] = Measure(11.25)
        host.setDisplaySettings(settings, id: screen.id)
        let domainState = host.registry.states
        var didChange = 0
        host.presentationChanged = { didChange += 1 }

        var draft = PanelSizeDraft(settings)
        draft.width.enter("2.5")
        draft.height.enter("1.5625")
        let atMinimum = try #require(draft.settings(over: settings, on: screen)?.panel(on: screen, fallbackEdge: .right))
        #expect(atMinimum.width == PanelSizeMetrics.minimumSide && atMinimum.height == PanelSizeMetrics.minimumSide)
        draft.width.convert(to: .points, extent: 800)
        draft.width.enter("186.375")
        #expect(didChange == 0 && store.value.displays[screen.id] == settings)

        settings.measures[.rowGap] = Measure(5.5) // An independent settings change while the size editor is open.
        host.setDisplaySettings(settings, id: screen.id)
        let edited = try #require(draft.settings(over: settings, on: screen))
        host.setDisplaySettings(edited, id: screen.id)
        #expect(didChange == 2)
        #expect(edited.measures[.panelWidth] == Measure(186.375) && edited.measures[.panelHeight] == Measure(1.5625, .percent))
        #expect(edited.measures[.rowGap] == Measure(5.5) && edited.measures[.reservedWidth] == Measure(113))
        host.stop()
        await host.start()
        #expect(store.value.displays["main"] == other && host.configuration.displays[screen.id] == edited)
        #expect(host.registry.states == domainState)
        draft = PanelSizeDraft()
        let reset = try #require(draft.settings(over: edited, on: screen))
        #expect(host.configuration.displays[screen.id] == edited)
        host.setDisplaySettings(reset, id: screen.id)
        #expect(store.value.displays[screen.id] == settings && store.value.displays["main"] == other)
    }

    @Test func invalidOrPartialInputCannotReplaceTheOtherDimension() {
        let rect = SurfaceRect(width: 800, height: 1280)
        let screen = ScreenGeometry(id: "secondary", frame: rect, visibleFrame: rect)
        var prior = DisplaySettings()
        prior.measures[.panelHeight] = DisplayMetric.panelHeight.factory
        var draft = PanelSizeDraft(prior)
        for invalid in ["", "-", "nan", "inf", "101"] {
            draft.width.enter(invalid)
            #expect(draft.settings(over: prior, on: screen) == nil)
        }
        draft.width.enter("9.75")
        let valid = draft.settings(over: prior, on: screen)
        #expect(valid?.measures[.panelHeight] == prior.measures[.panelHeight])
        #expect(valid?.measures[.panelWidth] == Measure(9.75, .percent))
        #expect(prior.measures[.panelWidth] == nil)
    }
    @Test func previewAndCommitShareTheScreenBoundsWithoutRoundingFractionalInput() throws {
        let available = SurfaceRect(width: 800, height: 1280)
        let screen = ScreenGeometry(id: "secondary", frame: available, visibleFrame: available)
        var original = DisplaySettings()
        original.measures[.sideInset] = Measure(12.25)
        original.measures[.topInset] = Measure(6)
        original.measures[.bottomInset] = Measure(17)
        var draft = PanelSizeDraft(original)
        draft.width.convert(to: .points, extent: 800)
        draft.height.convert(to: .points, extent: 1280)
        draft.width.enter("1e307")
        draft.height.enter("0")
        let clamped = try #require(draft.settings(over: original, on: screen))
        #expect(clamped.measures[.panelWidth] == Measure(787.75))
        #expect(clamped.measures[.panelHeight] == Measure(PanelSizeMetrics.minimumSide))
        let layout = try #require(PanelSizeLayout(settings: clamped, screen: screen, edge: .right,
                                                 content: .full, voice: true, tray: true, floating: false))
        #expect(layout.frame.width == 787.75 && layout.frame.height == PanelSizeMetrics.minimumSide)
        draft.height.enter("347.625")
        let resized = try #require(draft.settings(over: original, on: screen))
        #expect(resized.measures[.panelHeight] == Measure(347.625))
    }
}
