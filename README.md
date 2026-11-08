# Nearpane

**A persistent, modular interaction layer for the Mac desktop.**

Nearpane brings real macOS Spaces, windows, and displays together with two first-party always-on capabilities — Saytile voice input and Riftlet screenshot capture — plus user-configurable modules such as an AI assistant, notes, tasks, calendar, clock, and weather.

The goal is to make the desktop itself a visible, actionable workspace: users can understand and switch between real desktop spaces, keep essential tools within reach, and choose which additional capabilities deserve a permanent place in their workflow.

## Product capabilities

- **Desktop orchestration:** Visualize real macOS Spaces and their actual windows, preserving window geometry, proportions, positions, and overlap. Click a Space to switch to it or a visible window to activate it, subject to verified system capabilities.
- **Saytile voice input:** Keep one continuous, editable, faithfully transcribed text stream within reach.
- **Riftlet screenshot tray:** Capture and stage screenshots, then attach them to the intended draft through Riftlet's existing interaction and recovery model. Capturing or attaching never means automatically sending.
- **Configurable modules:** Let users choose additional always-available tools, including AI assistance, notes, tasks, calendar, clock, weather, and future modules.

Nearpane observes and enhances the native macOS desktop. It does not replace Spaces with a virtual desktop system, and it does not turn the main panel into a conventional Dock or generic widget dashboard.

## Product and design authority

- [Product Definition](docs/PRODUCT_DEFINITION.md) — positioning, three-layer product architecture, core capabilities, configurable modules, principles, and boundaries.
- [Visual Authority](docs/design/NEARPANE-VISUAL-AUTHORITY.md) — approved edge-panel visual direction, default proportions, Space mapping, and real-window geometry rules.
- [Approved visual reference](docs/design/assets/nearpane-visual-authority.webp) — approved visual-direction image.

## Integrated design package

The design branch contains the complete continuation package:

- [macOS Spaces feasibility and evidence boundary](docs/architecture/MACOS-SPACES-FEASIBILITY.md)
- [Overall architecture and Saytile/Riftlet integration](docs/architecture/NEARPANE-ARCHITECTURE.md)
- [User-configurable module system](docs/architecture/USER-MODULE-SYSTEM.md)
- [Interaction specification](docs/design/INTERACTION-SPEC.md)
- [Interactive HTML prototype](docs/prototype/nearpane-interaction-prototype.html)
- [Engineering implementation roadmap](docs/engineering/IMPLEMENTATION-ROADMAP.md)
- [Delivery and verification manifest](docs/DELIVERY-AND-VERIFICATION.md)

The default visual baseline remains a narrow edge surface (approximately one-eighth of the screen width), without a title, logo, or product-name header. Saytile and Riftlet occupy the upper tool area; the lower area presents real macOS Spaces. User-configurable modules use compact resident entries and expanded overlays so that adding modules does not silently compress the approved core geometry.

## Project status

These documents define the intended product and engineering plan. They do not claim that all described capabilities have been implemented or validated. Product design, engineering implementation, and real-world macOS validation are tracked separately. In particular, complete multi-display Spaces enumeration and switching remain subject to the OS-version capability matrix and evidence requirements in the Spaces feasibility report.
