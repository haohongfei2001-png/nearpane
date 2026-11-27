# Host management-window audit

Source: `8c88457332cf55633d071b2992932a1971ded321`.

This is a static call-chain review of the ordinary Nearpane Host, separate from the packaged native receipt. No source was changed by this audit.

| Entry | Reviewed ownership |
| --- | --- |
| Main window | `NearpaneApp.showSettings()` constructs an `NSWindow` only when the retained controller is absent; closing does not release it. |
| Voice and screenshot settings/history | `EmbeddedModules.openManagementPage` routes to the main window. Library settings links change `SettingsNavigation`. |
| Lyrics settings, full lyrics, sources, timing and candidates | `NearpaneLyricsModule` sends a Host callback; `HostLyricsManagementView` supplies embedded content. The Host's welcome entry uses its module page. |
| Permissions on primary and secondary sidebars | `WindowAccessGuide` calls `openPermissions`; the secondary surface receives a navigation callback without domain module instances. Both route to the main Permissions page. |
| About and update UI | `ApplicationUpdater` supplies the embedded Sparkle user driver and requests the main About & Updates page. |
| Profile changes | Replace content in the retained main window. |

No remaining ordinary Host call path to an independent module management window was found. Shared `LyricAuxiliaryController` and `LyricPanelController` types remain for standalone-source compatibility, but the Host does not instantiate them.

Other window constructors belong to the desktop/secondary/fullscreen activity surfaces, immediate translation or transition overlays, or explicitly gated native acceptance fixtures. System file pickers, permission interfaces and native confirmation/error dialogs retain their existing roles; they are not alternate module management pages.

This audit does not certify every possible runtime state. The native receipt separately records window identity/count after production menu targets, module callbacks, close/reopen, and navigation operations.
