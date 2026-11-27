func filmSlider(in window: NativeWindow) throws -> (AXUIElement, CGRect) {
    let root = try axWindow(for: window)
    var sliders: [(AXUIElement, CGRect)] = []
    var visited = 0
    func visit(_ element: AXUIElement, depth: Int) {
        guard depth < 16, visited < 300 else { return }
        visited += 1
        if string(element, kAXRoleAttribute) == kAXSliderRole,
           (attribute(element, kAXEnabledAttribute) as? NSNumber)?.boolValue == true,
           let bounds = axBounds(element), window.bounds.contains(bounds) {
            sliders.append((element, bounds))
        }
        for child in (attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []).prefix(80) { visit(child, depth: depth+1) }
    }
    visit(root, depth: 0)
    try require(sliders.count == 1, "No unique enabled slider is exposed inside the requested photography window.")
    return sliders[0]
}
func moveSmooth(to destination: CGPoint) throws {
    let origin = CGEvent(source: nil)?.location ?? destination
    for index in 1...12 {
        let t = Double(index)/12
        let eased = t*t*(3-2*t)
        let position = CGPoint(x: origin.x + (destination.x-origin.x)*eased, y: origin.y + (destination.y-origin.y)*eased)
        try post(.mouseMoved, at: position)
        RunLoop.main.run(until: Date().addingTimeInterval(0.015))
    }
}
func dragFilmSlider(_ request: PointerRequest, window: NativeWindow, evidence: inout [String: Any]) throws {
    let (slider, bounds) = try filmSlider(in: window)
    let minimum = (attribute(slider, kAXMinValueAttribute) as? NSNumber)?.doubleValue ?? 0
    let maximum = (attribute(slider, kAXMaxValueAttribute) as? NSNumber)?.doubleValue ?? 1
    let value = (attribute(slider, kAXValueAttribute) as? NSNumber)?.doubleValue ?? minimum
    try require(maximum > minimum, "Slider has no usable observed range.")
    let fraction = min(1,max(0,(value-minimum)/(maximum-minimum)))
    let inset = min(bounds.height*0.25,bounds.width*0.04)
    let from = CGPoint(x: bounds.minX+inset+(bounds.width-2*inset)*fraction, y: bounds.midY)
    let to = CGPoint(x: bounds.minX+inset+(bounds.width-2*inset)*0.30, y: bounds.midY)
    try requireHit(from, request: request, window: window, button: slider, evidence: &evidence)
    try require(window.bounds.contains(to), "Slider drag target is outside its freshly observed window.")
    evidence["sliderBounds"] = rectangle(bounds)
    evidence["observedSliderRange"] = [minimum,maximum]
    evidence["observedSliderValue"] = value
    evidence["dragStart"] = point(from); evidence["dragEnd"] = point(to)
    try moveSmooth(to: from)
    try post(.leftMouseDown, at: from)
    var path: [[String: Double]] = []
    for index in 1...18 {
        let t = Double(index)/18
        let eased = t*t*(3-2*t)
        let position = CGPoint(x: from.x+(to.x-from.x)*eased, y: from.y)
        try post(.leftMouseDragged, at: position)
        path.append(point(position))
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
    }
    try post(.leftMouseUp, at: to)
    evidence["actualCGEventDragPath"] = path
}
