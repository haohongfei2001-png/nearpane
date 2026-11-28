# Native 2x capture environment (isolated CI runner only)

This helper changes the capture environment, not LyricTile. It does not redraw the
view or set a synthetic displayScale/contentsScale. It is untested until the cloud
Mac executes it; no successful HiDPI capture is claimed from source inspection.

## Compile and diagnose first

```sh
clang -fobjc-arc -O2 -framework AppKit -framework Foundation -framework CoreGraphics \
  Marketing/FirstFilm/native/np-virtual-hidpi.m -o /tmp/np-virtual-hidpi
/tmp/np-virtual-hidpi --probe > /tmp/np-displays-before.json
/tmp/np-virtual-hidpi --select-existing --output /tmp/np-hidpi-selected.json
```

`--probe` prints every online display and every exposed mode, including pixel and
logical dimensions, IO mode ID/flags, refresh rate, AppKit frame/backing scale,
and candidate screen indices. `--select-existing` returns 0 only after an actual
existing mode is at least 2x **and** the matching NSScreen reports scale >=2.
Exit 2 means no existing mode qualified. Merely requesting duplicate low-resolution
modes cannot create HiDPI capability.

## Create only if no existing mode works

```sh
/tmp/np-virtual-hidpi --create --width 1920 --height 1080 --seconds 1800 \
  --output /tmp/np-hidpi-virtual.json > /tmp/np-hidpi-virtual.log 2>&1 &
np_virtual_pid=$!
```

Wait for the JSON and inspect `ready` (do not infer success from process creation).
The helper holds the CGVirtualDisplay object until SIGTERM/SIGINT or the deadline.
Keep it alive for the entire Swift test and recording. At completion terminate
only this helper PID. This is an extended display, not a mirror of the 1x display.

The requested physical framebuffer is 1920x1080; HiDPI mode size is 960x540,
following Chromium's own implementation. Private API classes are checked at
runtime. A nonzero vendor ID and per-process serial are supplied. Public
CoreGraphics APIs select a true 2x mode if it is not initially selected.

## Put the single production view on the target screen

Read `selected.displayID`; in the capture process find that exact NSScreen by
`screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]`.
Create/move the actual NSWindow wholly within that screen's frame, using AppKit
coordinates. A 208x192-point unscaled view should then have a 416x384-pixel backing
rectangle. Verify these values on the actual window/view after it is visible:

```swift
let screen = NSScreen.screens.first {
    ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == targetDisplayID
}!
window.setFrameOrigin(NSPoint(x: screen.frame.minX + 100, y: screen.frame.minY + 100))
window.orderFrontRegardless()
// After the normal AppKit event cycle, record these facts in the manifest:
// window.screen's NSScreenNumber == targetDisplayID
// window.backingScaleFactor == 2
// hosting.convertToBacking(hosting.bounds).size == (416,384) for a 208x192 view
```

Remove the harness's 3x scaleEffect, environment displayScale override, and forced
CALayer contentsScale. Do not recreate the product UI at larger font/layout sizes.
Do not rely on the helper's NSScreen alone: the product window must actually move
to it. No product source change is required.

## Record the correct display

Prefer ScreenCaptureKit with the exact `SCDisplay.displayID` matching the selected
CGDisplayID. If retaining `screencapture -D`, its 1-based argument is **not** the
CGDisplayID. JSON supplies candidate NSScreen/active/online indices, not a claim
that those orders are the CLI's order. For each candidate, take one full-display
PNG and inspect its physical dimensions; choose the one matching the selected
mode's pixelWidth/pixelHeight (1920x1080 here versus the existing 1024x768 screen).
Retain that probe as evidence, then record that same `-D` display. If dimensions
are ambiguous, do not guess; use ScreenCaptureKit's displayID filter.

Record the full target screen, then crop the native physical panel rectangle in
postproduction. This avoids `-R` logical/global coordinate ambiguity. To convert
the view's window-space rectangle to a top-left pixel crop on its NSScreen, use
AppKit screen coordinates and the actual backing factor:

```
xPixels = (panelScreenRect.minX - screen.frame.minX) * scale
yPixels = (screen.frame.maxY - panelScreenRect.maxY) * scale
widthPixels = panelScreenRect.width * scale
heightPixels = panelScreenRect.height * scale
```

Keep ordinary WindowServer capture, not cacheDisplay or forced bitmap redraws.
A larger export resolution by itself does not prove a higher-density backing.

## Evidence and limits

- Chromium implementation (primary source, BSD-style license):
  https://chromium.googlesource.com/chromium/src/+/HEAD/ui/display/mac/test/virtual_display_util_mac.mm
  Examined blob: 37e96927d1a2f68d2ee57797710520a790193c82. The implementation sets
  hiDPI=1 and halves the mode dimensions relative to descriptor maxPixels.
- Chromium explicitly excludes a headless-only environment in `IsAPIAvailable`
  (TODO: support headless bots). A GitHub runner may therefore reject creation or
  expose only 1x. The helper reports nil/init/apply/mode/backing errors; do not
  claim that this private path is guaranteed on macOS 27 or virtual machines.
- This is private API usage only in an isolated capture executable. It is not
  added to the shipping app and does not change any user's computer.
- Public mode APIs / Apple documentation:
  https://developer.apple.com/documentation/coregraphics/quartz-display-services
  https://developer.apple.com/documentation/coregraphics/kcgdisplayshowduplicatelowresolutionmodes
  https://developer.apple.com/documentation/coregraphics/cgdisplaymode/pixelwidth
  https://developer.apple.com/documentation/appkit/nsscreen/backingscalefactor
- No permanent display override, root access, reboot, SIP change or third-party
  application install is needed. Creation may still fail for platform reasons.
- Genuine 2x is the bounded goal. The hiDPI flag is not an arbitrary 3x setting.

If both existing-mode selection and virtual-display creation fail, stop this
route with its evidence. A larger 1x image must not be labeled a Retina capture.
