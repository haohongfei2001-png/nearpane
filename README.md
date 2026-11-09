# Nearpane

**A persistent, modular interaction layer for the Mac desktop.**

Nearpane offers user-selectable native macOS Spaces and Nearpane-managed virtual Workspaces, with faithful window views, voice input via Saytile, screenshot capture via Riftlet, and configurable modules such as an AI assistant, notes, tasks, calendar, clock, and weather.

The goal is to make the desktop itself a visible, actionable workspace: users can understand and switch between real desktop spaces, keep essential tools within reach, and choose which additional capabilities deserve a permanent place in their workflow.

## Product capabilities

- **Persistent desktop work area:** Non-native-fullscreen workspaces always reserve approximately one-eighth of the primary display, even while the Nearpane UI is partially or wholly hidden. Managed ordinary windows stay within the remaining seven-eighths; panels appearing or disappearing never cause ordinary windows to expand into the reserved strip.
- **Progressive workspace tiling:** Users primarily drag a specific window thumbnail from another workspace onto the target workspace. One window fills WorkRect; two split evenly; three place the previous two stacked in the right half and the newcomer in the left half; four and five progressively subdivide further, up to **eight** managed windows per workspace. A ninth is rejected, never silently hidden or moved. Manual window placement and split ratios are adjustable.
- **Space-level navigation:** Choose native macOS Spaces or Nearpane-managed virtual Workspaces. Clicking anywhere on one Space preview row switches that workspace as a whole, not an individual window.
- **True fullscreen and mini tools:** Real fullscreen hides Spaces and the full panel. User-configured compact status strip opens permitted movable tools (such as voice) only on explicit click; fullscreen exit defaults to the originating workspace, subject to verified OS capabilities.
- **Saytile voice input:** Keep one continuous, editable, faithfully transcribed text stream within reach.
- **Riftlet screenshot tray:** Capture and stage screenshots, then attach them to the intended draft through Riftlet's existing interaction and recovery model. Capturing or attaching never means automatically sending.
- **Configurable modules:** Let users choose additional always-available tools, including AI assistance, notes, tasks, calendar, clock, weather, and future modules.

Native mode is selected by default on first use, without a forced choice screen; Virtual is a low-frequency Settings option after capability and recovery validation. The product is sold and presented as one Nearpane application, not separate Saytile/Riftlet/Spaces purchases. Native mode observes and enhances macOS Spaces; Virtual mode manages its own logical Workspaces within the existing macOS desktop environment. Virtual Workspaces do not turn into Mission Control Spaces and do not require disabling macOS Spaces or SIP. The main panel is neither a Dock replacement nor a generic widget dashboard.

## Product and design authority

- [Product Definition](docs/PRODUCT_DEFINITION.md) — authoritative positioning, capabilities and dual workspace-mode choice.
- [Dual-mode decision ADR-010](docs/decisions/ADR-010-DUAL-WORKSPACE-MODES.md) — Native/Virtual scope, mode-switch safety, recovery and independent validation.
- [Multi-display presentation ADR-011](docs/decisions/ADR-011-MULTI-DISPLAY-PRESENTATION.md) — one primary resident panel, independent secondary Space-only panels and per-display sizing, placement, and appearance.
- [Reserved work area, tiling and fullscreen ADR-012](docs/decisions/ADR-012-DESKTOP-WORK-AREA-AND-FULLSCREEN.md) — original work-area, fullscreen, focus and unified-product decisions.
- [Stable work area and eight-window tiling ADR-013](docs/decisions/ADR-013-STABLE-WORKRECT-AND-EIGHT-WINDOW-TILING.md) — latest authority: UI visibility does not change work area, drag thumbnails into workspaces, progressive tiling with an eight-window cap.
- [Visual Authority](docs/design/NEARPANE-VISUAL-AUTHORITY.md) — approved edge-panel visual direction, default proportions, Space mapping, and real-window geometry rules.
- [Approved visual reference](docs/design/assets/nearpane-visual-authority.webp) — approved visual-direction image.

## Integrated design package

The design branch contains the complete continuation package:

- [macOS Spaces feasibility and evidence boundary](docs/architecture/MACOS-SPACES-FEASIBILITY.md)
- [Overall architecture and Saytile/Riftlet integration](docs/architecture/NEARPANE-ARCHITECTURE.md)
- [User-configurable module system](docs/architecture/USER-MODULE-SYSTEM.md)
- [Interaction specification](docs/design/INTERACTION-SPEC.md)
- [Historical interactive HTML prototype](docs/prototype/nearpane-interaction-prototype.html) — an earlier synthetic interaction demonstration; **not** current authority for window overlap or per-window preview clicking. ADR-012 supersedes those interactions.
- [Engineering implementation roadmap](docs/engineering/IMPLEMENTATION-ROADMAP.md)
- [Delivery and verification manifest](docs/DELIVERY-AND-VERIFICATION.md)

The default complete primary panel remains a narrow edge surface (approximately one-eighth of its display width), without a title, logo, or product-name header. All layout dimensions (panel and module sizes, thumbnails, Space rows, typography, controls, spacing, and radii) have approved defaults but are precisely adjustable per display in Settings; the persistent surface has no resize controls. Saytile and Riftlet appear only on one user-selected primary resident display, whose Spaces area remains visible whenever there are meaningful multi-space/multi-window targets, and can be omitted when no workspace navigation is needed, without ever releasing the reserved work area. Secondary displays show only separate, independently sized Space/Workspace panels: on-demand by default, or contextual-auto/pinned only if the user opts in. Fullscreen hides space orchestration by default; mini tools are user-invoked floating overlays, while the full-height non-fullscreen panel reserves real space from managed windows. User-configurable modules use compact resident entries and expanded overlays so that adding modules does not silently compress the approved core geometry.

## Project status

These documents define the intended product and engineering plan. They do not claim that all described capabilities have been implemented or validated. Product design, engineering implementation, and real-world macOS validation are tracked separately. In particular, complete multi-display Spaces enumeration and switching remain subject to the OS-version capability matrix and evidence requirements in the Spaces feasibility report.
