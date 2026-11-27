# Nearpane unified workbench — 2026-11-28

> Implementation checkpoint: the owner-approved [product constitution](../../PRODUCT_CONSTITUTION.md), added concurrently in `d73d1549`, is now authoritative and matches `main`. The resident-area order and advanced visual controls described below reflect the intermediate candidate; the next UI revision removes those restrictions and retired controls. Native downloadable module packages are not implemented by the current statically linked integration and must never be presented as if they were.

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

Enabled tools are listed in the same sequence as `LayoutComposer.toolOrder`. Drag a tool row onto another to move it before that tool, or drop at the end of the tool area. Each row remains directly clickable to open its detail. Ordinary module switches change enablement immediately. Disabled modules appear in a separate section and preserve their settings and data.

Spaces uses the same switch with one necessary lifecycle difference: its existing reversible window-return barrier must complete before the off state is committed. The module list and detail share one coordinator, so pending state and retry feedback stay consistent while navigating. A failed or superseded return keeps Spaces enabled and explains how to retry. The app's terminal shutdown latch is not used for a reversible module toggle; re-enabling Spaces remains possible.

Existing sidebar layout distinguishes content tools from the resident clock/Spaces area. This distinction is now explicit rather than implying that arbitrary drag positions will work. The clock sits beneath content tools; Spaces uses its existing elastic area. This change does not redesign Spaces scheduling or physical window behavior.

When all content modules are enabled, the layout first keeps the full lyric reading height and a useful Spaces area. Only crowded combinations borrow height from the voice viewport, screenshot cells, note and task list, never from their required controls. At a common 832-point available height, the five content tools plus clock retain a 96-point Spaces window area. Ordinary roomy combinations keep their previous exact geometry. Physically undersized panels expose the existing compact expansion control; a clipped note editor is no longer reported as a full layout. User-saved dimensions and typography remain unchanged.

Module capabilities describe sidebar presence, settings and optional user-content library. Lyric caches are not a Library destination. The built-in module catalog supplies user-facing descriptions and routes while keeping existing IDs and serialized preferences.

## Detail ownership

| Module | Module-owned controls/content | Shared settings inherited |
| --- | --- | --- |
| Voice / Saytile | Recognition provider, language, input readiness, module permissions; voice library link | Panel size/material/accent/placement |
| Screenshots / Riftlet | Collection directory, browser attachment access, library connection | Panel size/material/accent/placement |
| Lyrics / LyricTile | Preferred player, lyric lookup, text size, translation, cache; full lyrics, source, timing and matches | App lifecycle, main-window navigation, panel placement, updates |
| Spaces | Dispatch, window display and rules | Display selection, sidebar size/material |
| Note and tasks | Same content stored by sidebar; open Library | Shared appearance/placement |
| Clock | Extra time zone, existing pinned state | Shared appearance/placement |

The previous duplicate Spaces enable switch inside window presentation is removed; the module header is the common enable control. Theme color belongs to Appearance, and profile import/restore belongs to Data management. App update and feedback remain under About & Updates.

Advanced dimension controls also follow this ownership. `DisplaySettingsScope` filters the existing `DisplayMetricGroup` values: global exposes the shared panel and common resident-area metrics; voice, screenshot and Spaces details each expose only their own group in a collapsed Display style section. The editor writes the same existing per-display keys, so no preference is copied or migrated. A module scope can restore only its own group. The previously inactive scroll-height key is retained on disk but not offered as a working control. Spaces thumbnail height uses the actual content width as its percentage basis and defaults to a 50% width limit, matching the rendered card.

## Library behavior

The library is accessible independently of surface enablement. Voice retains its existing natural-paragraph browsing, search and detailed history. Copy paragraph reads every member, including content beyond the current page, and uses the latest saved revisions. Screenshots retain date-based thumbnails and previews; copy and drag use the validated original image instead of the thumbnail. A disabled module opens only its saved-content store and must not need to start its live capture service just to read history.

The note is a full editing surface for the existing single note, not a fictional collection of note documents. Edits write through the existing `SidebarNotebook`. Tasks offer all/open/completed filters, completion and inline deletion confirmation. Vocabulary offers source/translation search, copy and inline deletion confirmation. No second storage schema or migration is introduced.

## Playback and auxiliary pages

A paused valid music session retains the lyric surface indefinitely, independent of hover. A short incomplete observation must not discard the session while its selected player remains alive. Confirmed current-player exit or explicit module disable withdraws the surface and releases space. Track changes and no-lyrics behavior continue to use existing lyric services.

The host lyric module delegates auxiliary page requests to the main window. Full lyrics, sources, timing, candidates and settings render in its content area. Standalone lyric welcome/settings/window controllers are not instantiated by Nearpane.

## Updates in the same window

Sparkle remains responsible for update discovery, download, verification and installation. Nearpane supplies an embedded `SPUUserDriver`: check progress, release notes, download progress, errors, automatic-check permission and the final installation choice appear in About & Updates. Menu-initiated checks first focus that destination. The driver does not create a separate updater window, alert or sheet. Installation still passes through the existing activity and window-restoration admission checks.

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
