import AppKit
import CoreText
import LyricCore
import SwiftUI

/// Native shaping is cached by text, typography and width. Only the clip mask changes per frame.
public struct LyricGlyphText: NSViewRepresentable {
    public let cue: LyricDomain.Cue
    public let anchor: LyricDomain.PlaybackAnchor?
    public let sourceAdvanceMS: Int64
    public let userAdvanceMS: Int64
    public let tokenHighlight: Bool
    public let animate: Bool
    public let fontSize: CGFloat
    public let dark: Bool
    public let browse: @MainActor (Int) -> Void

    public init(cue: LyricDomain.Cue, anchor: LyricDomain.PlaybackAnchor?, sourceAdvanceMS: Int64,
                userAdvanceMS: Int64, tokenHighlight: Bool, animate: Bool, fontSize: CGFloat,
                dark: Bool, browse: @escaping @MainActor (Int) -> Void) {
        self.cue = cue; self.anchor = anchor; self.sourceAdvanceMS = sourceAdvanceMS
        self.userAdvanceMS = userAdvanceMS; self.tokenHighlight = tokenHighlight
        self.animate = animate; self.fontSize = fontSize; self.dark = dark; self.browse = browse
    }
    public func makeNSView(context: Context) -> LyricGlyphView { LyricGlyphView(frame: .zero) }
    public func updateNSView(_ view: LyricGlyphView, context: Context) {
        let sum = sourceAdvanceMS.addingReportingOverflow(userAdvanceMS)
        view.configure(cue: cue, anchor: sum.overflow ? nil : anchor, advance: sum.overflow ? 0 : sum.partialValue,
                       tokenHighlight: tokenHighlight && !sum.overflow, animate: animate && !sum.overflow, fontSize: fontSize,
                       dark: dark, browse: browse)
    }
    public static func dismantleNSView(_ view: LyricGlyphView, coordinator: ()) { view.stopClock() }
}

@MainActor
public final class LyricGlyphView: NSView {
    private struct GlyphBox {
        let range: NSRange
        let rect: CGRect
        let rightToLeft: Bool
        let row: Int
    }
    private struct Row {
        let line: CTLine
        let x: CGFloat
        let baseline: CGFloat
    }
    private var cue: LyricDomain.Cue?
    private var anchor: LyricDomain.PlaybackAnchor?
    private var advance: Int64 = 0
    private var usesTokens = false
    private var animate = false
    private var fontSize: CGFloat = 20
    private var dark = false
    private var cachedWidth: CGFloat = -1
    private var rows: [Row] = []
    private var boxes: [GlyphBox] = []
    private var tokenBoxes: [String: [GlyphBox]] = [:]
    private var maskLayoutValid = true
    private var totalHeight: CGFloat = 0
    private var verticalOffset: CGFloat = 0
    private var manuallyScrolled = false
    private var drewUpcomingCue = false
    private var timer: Timer?
    private var browse: (@MainActor (Int) -> Void)?
    private var lastBrowseAt: TimeInterval = 0
    public override var isFlipped: Bool { true }
    public override var acceptsFirstResponder: Bool { false }

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }
    public required init?(coder: NSCoder) { return nil }

    public func configure(cue: LyricDomain.Cue, anchor: LyricDomain.PlaybackAnchor?, advance: Int64,
                          tokenHighlight: Bool, animate: Bool, fontSize: CGFloat, dark: Bool,
                          browse: @escaping @MainActor (Int) -> Void) {
        let changed = self.cue != cue || self.fontSize != fontSize
        let clockChanged = self.usesTokens != tokenHighlight || self.animate != animate ||
            (tokenHighlight && (self.anchor != anchor || self.advance != advance))
        let redraw = changed || clockChanged || self.dark != dark
        self.cue = cue; self.anchor = anchor; self.advance = advance
        self.usesTokens = tokenHighlight; self.animate = animate; self.fontSize = fontSize
        self.dark = dark; self.browse = browse
        if changed {
            cachedWidth = -1; verticalOffset = 0; manuallyScrolled = false
            setAccessibilityLabel(cue.text)
        }
        let upcoming = cue.sourceStartMS.flatMap { start in lookup().map { $0 < start } } ?? false
        if redraw || upcoming != drewUpcomingCue { needsDisplay = true }
        if changed || clockChanged { scheduleClock() }
    }
    public override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); scheduleClock() }
    public override func layout() {
        super.layout()
        if abs(cachedWidth - bounds.width) > 0.5 { rebuildLayout(); needsDisplay = true }
    }
    public func stopClock() { timer?.invalidate(); timer = nil }

    private var lineHeight: CGFloat { fontSize >= 22 ? 29 : fontSize <= 18 ? 25 : 27 }
    /// Short lines sit in the middle of the lyric band. Longer cues expose whole
    /// rows at rest, while the existing native scroll gesture can reveal the rest.
    private var viewportHeight: CGFloat {
        min(totalHeight, max(lineHeight, floor(bounds.height / lineHeight) * lineHeight), bounds.height)
    }

    private func rebuildLayout() {
        cachedWidth = bounds.width
        rows = []; boxes = []; tokenBoxes = [:]; totalHeight = 0; maskLayoutValid = true
        guard let cue, bounds.width > 1, !cue.text.isEmpty else { return }
        let style = NSMutableParagraphStyle()
        style.alignment = .natural
        style.baseWritingDirection = .natural
        style.minimumLineHeight = lineHeight; style.maximumLineHeight = lineHeight
        style.lineBreakMode = .byWordWrapping
        let attributed = NSAttributedString(string: cue.text, attributes: [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .medium),
            .paragraphStyle: style,
            NSAttributedString.Key(rawValue: kCTForegroundColorFromContextAttributeName as String): true
        ])
        let setter = CTFramesetterCreateWithAttributedString(attributed)
        let contentHeight: CGFloat = 65_536
        let path = CGPath(rect: CGRect(x: 0, y: 0, width: bounds.width, height: contentHeight), transform: nil)
        let frame = CTFramesetterCreateFrame(setter, CFRange(location: 0, length: 0), path, nil)
        let lines = CTFrameGetLines(frame) as! [CTLine]
        var origins = Array(repeating: CGPoint.zero, count: lines.count)
        if !origins.isEmpty { CTFrameGetLineOrigins(frame, CFRange(location: 0, length: 0), &origins) }
        for (rowIndex, line) in lines.enumerated() {
            let origin = origins[rowIndex]
            let baseline = contentHeight - origin.y
            rows.append(Row(line: line, x: origin.x, baseline: baseline))
            let runs = CTLineGetGlyphRuns(line) as! [CTRun]
            for run in runs {
                let count = CTRunGetGlyphCount(run)
                guard count > 0 else { continue }
                var positions = Array(repeating: CGPoint.zero, count: count)
                var advances = Array(repeating: CGSize.zero, count: count)
                var indices = Array(repeating: CFIndex(0), count: count)
                CTRunGetPositions(run, CFRange(location: 0, length: 0), &positions)
                CTRunGetAdvances(run, CFRange(location: 0, length: 0), &advances)
                CTRunGetStringIndices(run, CFRange(location: 0, length: 0), &indices)
                let runRange = CTRunGetStringRange(run)
                let runEnd = runRange.location + runRange.length
                let boundaries = Array(Set(indices.filter { $0 >= 0 } + [runEnd])).sorted()
                let rtl = CTRunGetStatus(run).contains(.rightToLeft)
                var ascent: CGFloat = 0, descent: CGFloat = 0
                _ = CTRunGetTypographicBounds(run, CFRange(location: 0, length: 0), &ascent, &descent, nil)
                // Merge a cluster's glyphs, including combining marks, before masking.
                var clusters: [Int: CGRect] = [:]
                for index in 0..<count where indices[index] >= 0 {
                    let width = max(1, abs(advances[index].width))
                    let rect = CGRect(x: origin.x + positions[index].x, y: baseline - ascent,
                                      width: width, height: ascent + descent)
                    clusters[indices[index]] = clusters[indices[index]].map { $0.union(rect) } ?? rect
                }
                for (index, rect) in clusters {
                    let end = boundaries.first(where: { $0 > index }) ?? runEnd
                    guard end > index else { continue }
                    boxes.append(GlyphBox(range: NSRange(location: index, length: end - index), rect: rect,
                                          rightToLeft: rtl, row: rowIndex))
                }
            }
        }
        totalHeight = CGFloat(rows.count) * lineHeight
        let text = cue.text as NSString
        for token in cue.tokens {
            let range = NSRange(location: token.rangeInCue.location, length: token.rangeInCue.length)
            guard range.location >= 0, range.length > 0, range.location <= text.length,
                  range.length <= text.length - range.location,
                  text.rangeOfComposedCharacterSequences(for: range) == range else { maskLayoutValid = false; continue }
            // Preserve native ligature/RTL shaping; never rebuild a word as disconnected Characters.
            tokenBoxes[token.id] = boxes.filter { NSIntersectionRange($0.range, range).length > 0 }
                .sorted { $0.range.location == $1.range.location ? $0.row < $1.row : $0.range.location < $1.range.location }
            // A timing boundary cutting through an indivisible shaped ligature has no reliable
            // caret geometry here. Keep the native line readable rather than highlight wrong glyphs.
            if tokenBoxes[token.id]?.contains(where: { NSIntersectionRange($0.range, range).length < $0.range.length }) == true {
                maskLayoutValid = false
            }
        }
    }

    private func lookup() -> Int64? {
        guard let anchor, let position = anchor.positionMS,
              anchor.quality != .unavailable, anchor.quality != .stale else { return nil }
        let now = PlaybackClock.now()
        guard now.clockDomainID == anchor.observedAt.clockDomainID,
              now.nanoseconds >= anchor.observedAt.nanoseconds else { return nil }
        let elapsed = Double(now.nanoseconds - anchor.observedAt.nanoseconds) / 1_000_000
        guard anchor.state != .unknown, anchor.playbackRate.isFinite,
              anchor.state != .playing || elapsed <= 15_000 else { return nil }
        let value = Double(position) + (anchor.state == .playing ? elapsed * max(0, anchor.playbackRate) : 0) + Double(advance)
        guard value.isFinite, value > Double(Int64.min), value < Double(Int64.max) else { return nil }
        return Int64(value)
    }

    public override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if cachedWidth != bounds.width { rebuildLayout() }
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let time = lookup()
        let highlightTokens = usesTokens && maskLayoutValid
        if highlightTokens, !manuallyScrolled, let time, let cue,
           let active = cue.tokens.last(where: { $0.sourceStartMS <= time }),
           let row = tokenBoxes[active.id]?.first?.row {
            verticalOffset = min(max(0, totalHeight - viewportHeight), CGFloat(max(0, row - 1)) * lineHeight)
        }
        verticalOffset = min(verticalOffset, max(0, totalHeight - viewportHeight))
        let inset = max(0, (bounds.height - viewportHeight) / 2)
        context.saveGState()
        context.clip(to: CGRect(x: 0, y: inset, width: bounds.width, height: viewportHeight))
        context.translateBy(x: 0, y: inset - verticalOffset)
        let upcoming = cue?.sourceStartMS.flatMap { start in time.map { $0 < start } } ?? false
        drewUpcomingCue = upcoming
        drawRows(context, color: highlightTokens || upcoming ? LyricPalette.secondary(dark: dark) : LyricPalette.primary(dark: dark))
        if highlightTokens, let time, let cue {
            var mask: [CGRect] = []
            for token in cue.tokens where time >= token.sourceStartMS {
                guard let fragments = tokenBoxes[token.id] else { continue }
                let progress: Double
                if let end = token.sourceEndMS, end > token.sourceStartMS {
                    progress = min(1, max(0, Double(time - token.sourceStartMS) / Double(end - token.sourceStartMS)))
                } else {
                    // Known onset, unknown end: discrete activation, never fabricated word duration.
                    progress = 1
                }
                var remaining = fragments.reduce(CGFloat(0)) { $0 + $1.rect.width } * CGFloat(progress)
                for fragment in fragments {
                    let width = min(fragment.rect.width, max(0, remaining))
                    if width > 0 {
                        var rect = fragment.rect
                        if fragment.rightToLeft { rect.origin.x += rect.width - width }
                        rect.size.width = width
                        mask.append(rect)
                    }
                    remaining -= fragment.rect.width
                }
            }
            if !mask.isEmpty {
                context.saveGState(); context.clip(to: mask)
                drawRows(context, color: LyricPalette.primary(dark: dark))
                context.restoreGState()
            }
        }
        context.restoreGState()
    }
    private func drawRows(_ context: CGContext, color: NSColor) {
        context.setFillColor(color.cgColor)
        for row in rows where row.baseline >= verticalOffset - lineHeight && row.baseline < verticalOffset + viewportHeight + lineHeight {
            context.saveGState()
            context.translateBy(x: row.x, y: row.baseline)
            context.scaleBy(x: 1, y: -1)
            context.textMatrix = .identity; context.textPosition = .zero
            CTLineDraw(row.line, context)
            context.restoreGState()
        }
    }
    private func scheduleClock() {
        stopClock()
        guard animate, usesTokens, maskLayoutValid, window != nil, !isHiddenOrHasHiddenAncestor,
              let cue, let time = lookup() else { return }
        let active = cue.tokens.contains { token in
            guard let end = token.sourceEndMS else { return false }
            return time >= token.sourceStartMS && time < end
        }
        let interval: TimeInterval
        if active { interval = 1 / (ProcessInfo.processInfo.isLowPowerModeEnabled ? 30.0 : 60.0) }
        else if let start = cue.tokens.map(\.sourceStartMS).filter({ $0 > time }).min() {
            interval = min(2, max(0.008, (Double(start) - Double(time)) / 1000))
        } else { return }
        let timer = Timer(timeInterval: interval, target: self, selector: #selector(clockTick), userInfo: nil, repeats: false)
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
    @objc private func clockTick() { needsDisplay = true; scheduleClock() }
    public override func scrollWheel(with event: NSEvent) {
        let previous = verticalOffset
        verticalOffset = min(max(0, totalHeight - viewportHeight), max(0, verticalOffset - event.scrollingDeltaY))
        if abs(previous - verticalOffset) > 0.1 {
            manuallyScrolled = true; needsDisplay = true
        } else if abs(event.scrollingDeltaY) > 0.5, ProcessInfo.processInfo.systemUptime - lastBrowseAt > 0.25 {
            lastBrowseAt = ProcessInfo.processInfo.systemUptime
            browse?(event.scrollingDeltaY < 0 ? 1 : -1)
        }
    }
}
