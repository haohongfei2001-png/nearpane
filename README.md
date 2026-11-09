# Nearpane

**A persistent, modular interaction layer for the Mac desktop.**

Nearpane offers user-selectable native macOS Spaces and Nearpane-managed virtual Workspaces, with faithful window views, voice input via Saytile, screenshot capture via Riftlet, and configurable modules such as an AI assistant, notes, tasks, calendar, clock, and weather.

The goal is to make the desktop itself a visible, actionable workspace: users can understand and switch between real desktop spaces, keep essential tools within reach, and choose which additional capabilities deserve a permanent place in their workflow.

## Product capabilities

- **Persistent desktop work area:** Both the primary panel and each secondary Space-only panel default to **Docked**, permanently reserving an independently configured edge area even when the UI is hidden. A secondary panel can be set to **Floating**, in which case it never reserves any area, whether visible or hidden. Ordinary windows never resize solely because a panel appears or disappears.
- **New windows and progressive tiling:** Nearpane's product default places each newly opened ordinary app window in a **new independent workspace**, with a Settings option to join an existing workspace. This is not macOS's universal default. Users drag window thumbnails to group them intentionally; approved 1–8-window tiling stays unchanged. **Eight is a separate overflow threshold, not a hard cap**: on overflow prefer creating a workspace, falling back to further splitting if unavailable; Settings also offer Continuous Split. Native Space creation/removal is subject to verified OS capability and safety gates.
- **Space-level navigation:** Choose native macOS Spaces or Nearpane-managed virtual Workspaces. Clicking anywhere on one Space preview row switches that workspace as a whole, not an individual window.
- **True fullscreen and mini tools:** Real fullscreen hides Spaces and the full panel. User-configured compact status strip opens permitted movable tools (such as voice) only on explicit click; fullscreen exit defaults to the originating workspace, subject to verified OS capabilities.
- **Saytile voice input:** Keep one continuous, editable, faithfully transcribed text stream within reach.
- **Riftlet screenshot tray:** Capture and stage screenshots, then attach them to the intended draft through Riftlet's existing interaction and recovery model. Capturing or attaching never means automatically sending.
- **Configurable modules:** Let users choose additional always-available tools, including AI assistance, notes, tasks, calendar, clock, weather, and future modules.

Native mode is selected by default on first use, without a forced choice screen; Virtual is a low-frequency Settings option after capability and recovery validation. The product is sold and presented as one Nearpane application, not separate Saytile/Riftlet/Spaces purchases. Native mode observes and enhances macOS Spaces; Virtual mode manages its own logical Workspaces within the existing macOS desktop environment. Virtual Workspaces do not turn into Mission Control Spaces and do not require disabling macOS Spaces or SIP. The main panel is neither a Dock replacement nor a generic widget dashboard.

**Latest decisions (2026-11-09):** When the final real window leaves a workspace, Nearpane safely removes that now-empty source workspace (Native only if genuine system deletion is supported and verified; Virtual via a recoverable logical delete). Settings can exclude specific apps/windows from automatic management. Manually dismissing the Space view takes precedence over auto-show until the user summons it again, as with Mission Control. **Quit** reverses automatic management changes while preserving explicitly customized layout intentions; merely hiding Nearpane preserves Docked reservations. On relaunch, Nearpane **automatically resumes full management** of current safe, authorized windows, retaining exclusions and preferences. A three-to-two window transition restores the same pair's saved custom arrangement, otherwise 50:50. These are product specifications, **not runtime verification claims**.

## Product and design authority

- [Product Definition](docs/PRODUCT_DEFINITION.md) — authoritative positioning, capabilities and dual workspace-mode choice.
- [Dual-mode decision ADR-010](docs/decisions/ADR-010-DUAL-WORKSPACE-MODES.md) — Native/Virtual scope, mode-switch safety, recovery and independent validation.
- [Multi-display presentation ADR-011](docs/decisions/ADR-011-MULTI-DISPLAY-PRESENTATION.md) — one primary resident panel, independent secondary Space-only panels and per-display sizing, placement, and appearance.
- [Reserved work area, tiling and fullscreen ADR-012](docs/decisions/ADR-012-DESKTOP-WORK-AREA-AND-FULLSCREEN.md) — original work-area, fullscreen, focus and unified-product decisions.
- [Latest desktop and workspace lifecycle ADR-013](docs/decisions/ADR-013-STABLE-WORKRECT-AND-EIGHT-WINDOW-TILING.md) — new-window workspace default, overflow options, empty-workspace cleanup, app/window exclusions, manual view dismissal, per-display occupancy, user-intent preservation and relaunch takeover.
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
