# Nearpane unified workbench — 2026-11-28

> Implementation checkpoint: the owner-approved [product constitution](../../PRODUCT_CONSTITUTION.md), introduced in `d73d1549` and extended with four-edge requirements in `b2112280`, is authoritative. This revision replaces the intermediate candidate's protected resident order with one freely ordered stack and retires its detailed visual controls. The current implementation still has left/right desktop edges; it does not claim the new top/bottom or horizontal-layout qualification. Native downloadable module packages are not implemented by the current statically linked integration and must never be presented as if they were. Implementation remains distinct from native acceptance.

## Product decision

Nearpane has two surfaces: the everyday desktop sidebar and one retained management window. The management window owns module composition, user content and app configuration. It does not become another activity surface competing with the sidebar.

The window opens at Modules. The first experience answers what Nearpane contains and lets people choose what they need. Voice or screenshot history is no longer the default landing page. There are exactly three primary destinations:

| Destination | Responsibility | Contents |
| --- | --- | --- |
| Modules | Decide what belongs in the sidebar and configure each tool | Enabled tools in visible order; inactive modules; per-module details |
| Library | Read and manage saved user work | Voice paragraphs, screenshots, note, tasks, saved vocabulary |
| Settings | Configure the shared app | General, appearance/layout, display/placement, permissions, data, about/update |

Library and Settings remember their last page when people switch primary sections. Every menu or sidebar deep link selects an internal route in the same window. Module details have a visible return to Modules. The Spaces detail groups dispatch, window presentation and rules into a segmented control within that page.

## Visual design

- Default management content size: **920 × 660 points**. Minimum: **740 × 520**. Host retains frame and prevents new windows for repeated requests.
- A **184 point** material sidebar reduces to **164 points** below 850 point window width. It holds only three prominent destinations, followed by the current section's pages.
- Content starts at **28 point** horizontal margins. The page title is **22 point semibold**; navigation 12–13 point; module row titles 14 point, descriptions 12 point. SF Symbols use a consistent 20 point footprint within module rows.
- The module list uses rows, quiet separators and small system switches. It avoids app-store tiles, installation controls, marketing text, ratings, excessive borders and global grids of cards.
- System foreground/background styles adapt to light, dark, and increased contrast. The existing Nearpane accent is shared across navigation and module controls. Material is confined to navigation; reading surfaces retain stable contrast.
- The sidebar remains the place for lyrics, windows, captured text and images. Management buttons, close handles and edit modes do not move into it.

The design follows macOS conventions for stable sidebar navigation and resizable content without introducing another Settings scene. Reference guidance: [Apple sidebars](https://developer.apple.com/design/human-interface-guidelines/sidebars), [Apple windows](https://developer.apple.com/design/human-interface-guidelines/windows), [Apple macOS design](https://developer.apple.com/design/human-interface-guidelines/designing-for-macos).

## Module composition and order

Enabled modules are listed in the same sequence as `LayoutComposer.toolOrder`. Every shipped module, including the clock and Spaces, can be dragged before another module or to the end. The registry retains the complete saved order across relaunch and appends newly available modules without changing existing preferences. Each row remains directly clickable to open its detail. Ordinary module switches change enablement immediately. Disabled modules appear in a separate section and preserve their settings and data.

Spaces uses the same switch with one necessary lifecycle difference: its existing reversible window-return barrier must complete before the off state is committed. The module list and detail share one coordinator, so pending state and retry feedback stay consistent while navigating. A failed or superseded return keeps Spaces enabled and explains how to retry. The app's terminal shutdown latch is not used for a reversible module toggle; re-enabling Spaces remains possible.

The implemented vertical composition has no protected resident area. The clock is a compact content row in its own ordered position, and Spaces occupies its user-selected position with the remaining useful height. Spaces retains its existing internal scrolling and window behavior; the placement change does not redesign its scheduler or dispatch admission.

When content crowds the viewport, voice, screenshot, note and task sections shrink only to usable design minima. Lyrics keep their full reading or compact-player height; the clock remains 40 points. Spaces has a 96-point minimum card viewport rather than a reserved fraction, and grows with the remaining space at any position. If the sum of usable minima exceeds the available height, the entire ordered stack scrolls: no enabled, presentable module is dropped. The native glass mask follows the scroll offset. Very narrow or icon-sized panels retain the existing expansion entry. Fullscreen tool content uses the same order while excluding Spaces; idle lyrics contribute no slot.

Module capabilities describe sidebar presence, settings and optional user-content library. Lyric caches are not a Library destination. The built-in module catalog supplies user-facing descriptions and routes while keeping existing IDs and serialized preferences.

## Detail ownership

| Module | Module-owned controls/content | Shared settings inherited |
| --- | --- | --- |
| Voice / Saytile | Recognition provider, language, input readiness, module permissions; voice library link | Panel size/material/accent/placement |
| Screenshots / Riftlet | Collection directory, browser attachment access, library connection | Panel size/material/accent/placement |
| Lyrics / LyricTile | Preferred player, lyric lookup, text size, translation, cache; full lyrics, source, timing and matches | App lifecycle, main-window navigation, panel placement, updates |
| Spaces | Dispatch, window display and rules | Display selection, sidebar size/material |
| Note and tasks | Same content stored by sidebar; open Library | Shared appearance/placement |
| Clock | Extra time zone | Shared appearance/placement; direct ordered presence while enabled |

The previous duplicate Spaces enable switch inside window presentation is removed; the module header is the common enable control. Theme color belongs to Appearance, and profile import/restore belongs to Data management. App update and feedback remain under About & Updates.

The product exposes one bounded sidebar-width control, the shared accent and one transparency adjustment. Voice text and window labels each offer small, standard and large typography choices in their module. Arbitrary per-element geometry, pt/% fields, separate module heights, corner radii, padding, icon/button sizes and per-field reset actions no longer appear, including in advanced sections. Their internal tokens remain available to layout code. The visual-policy migration retains retired values in `retiredVisualOverrides` and `retiredGlassOverrides`, while current rendering uses the designed defaults. Startup resolves this policy in memory; the original file is not rewritten merely by opening the app. Later normal preference saves preserve both the current values and the retired record. See [the settings migration record](2026-11-28-settings-convergence.md).

## Library behavior

The library is accessible independently of surface enablement. Voice retains its existing natural-paragraph browsing, search and detailed history. Copy paragraph reads every member, including content beyond the current page, and uses the latest saved revisions. Screenshots retain date-based thumbnails and previews; copy and drag use the validated original image instead of the thumbnail. A disabled module opens only its saved-content store and must not need to start its live capture service just to read history.

The note is a full editing surface for the existing single note, not a fictional collection of note documents. Edits write through the existing `SidebarNotebook`. Tasks offer all/open/completed filters, completion and inline deletion confirmation. Vocabulary offers source/translation search, copy and inline deletion confirmation. No second storage schema or migration is introduced.

## Playback and auxiliary pages

A paused valid music session retains the lyric surface indefinitely, independent of hover. A short incomplete observation must not discard the session while its selected player remains alive. Confirmed current-player exit or explicit module disable withdraws the surface and releases space. Track changes and no-lyrics behavior continue to use existing lyric services.

The host lyric module delegates auxiliary page requests to the main window. Full lyrics, sources, timing, candidates and settings render in its content area. Standalone lyric welcome/settings/window controllers are not instantiated by Nearpane.

## Updates in the same window

Sparkle remains responsible for update discovery, download, verification and installation. Nearpane supplies an embedded `SPUUserDriver`: check progress, release notes, download progress, errors, automatic-check permission and the final installation choice appear in About & Updates. Menu-initiated checks first focus that destination. The driver does not create a separate updater window, alert or sheet. Installation still passes through the existing activity and window-restoration admission checks.

## Fullscreen tool composition

The existing fullscreen status strip opens one temporary tool workspace. Its content reuses `EdgeSurfaceView`, the saved module order, the same module objects and the same layout calculation, excluding Spaces and currently empty lyrics. A bounded viewport scrolls when needed. The strip never expands automatically. Dragging and closing remain local presentation actions; only a deliberate click into an editable text field makes the panel key. Every input still passes the existing fullscreen-session admission check. Ordinary and fullscreen presentation exposure are combined, so one surface disappearing cannot incorrectly hide the active other surface or start another domain service.

This is a presentation change. It does not qualify real fullscreen entry/exit, screen-sharing compatibility or the underlying window manager; those require separate native observations.

## Four-edge follow-up boundary

The `b2112280` owner decision requires top/bottom edges, horizontal content, per-screen thickness and matching real window reservations. This candidate does not expose an inert top/bottom picker. A correct implementation needs axis-aware panel and work-area geometry, horizontal Spaces browsing, screenshot-arrival motion and compact lyric presentation without rotating text or distorting images. The existing R4 interface accepts general rectangles, so this does not require replacing its hidden-Space engine. Native four-edge avoidance, rotation, mixed-orientation displays and fullscreen return remain explicit open qualification items.

## Implementation map

- `MainWindowNavigation.swift`: three primary sections, route ownership, deep links and section memory.
- `SettingsView.swift`: shared navigation shell, page header, module/global settings separation.
- `ModuleManagementView.swift`: enable/disable, ordered tool list, drag insertion and inactive list.
- `ModuleSwitchCoordinator.swift`: shared module state changes and the existing Spaces return barrier, without changing its window-dispatch algorithm.
- `NotebookLibraryView.swift`: notes/tasks/vocabulary over the original store.
- `MainWindowGeneralSettings.swift`: menu visibility, sidebar visibility and native login-item status. Login registration only occurs after a user toggles it.
- `ModuleCapabilities.swift`: module destination metadata without changing saved preference IDs.
- `HostLyrics.swift` and lyric module: host-owned auxiliary routing and persistent paused-session presentation.

## Verification scope

Source tests, a successful build, actual UI screenshots, observed interactions and release eligibility are distinct results. `MainWindowNavigationTests` checks remembered page state and deep-link parent routing. The native acceptance harness checks actual retained window identity and screenshots across appearance/size modes. Playback tests and native playback evidence carry their own results.

This design document defines the implemented decisions; it is not itself proof of native acceptance. Actual receipts, source SHA and screenshots are recorded in the verification directory after the candidate run. No existing unresolved Spaces dispatch issue is counted as fixed by this work.
