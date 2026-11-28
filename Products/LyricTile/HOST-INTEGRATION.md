> **2026-11-28 产品规则更新：** [产品宪章](../../PRODUCT_CONSTITUTION.md) 优先。LyricTile 是平等、可按需下载/启停的 Nearpane 模块；暂停保持卡片及控制，退出播放器才撤下，所有管理功能走唯一主窗口。下文是早期集成候选记录，不等于新目标已完成。

# Nearpane bundled lyrics domain

Lyrics baseline: signed build 49, `b95b6f5ed7680cbde1427a4ed1a904bd5875e17b`.
Host baseline: R4 PR 16, `c64bf6d587247e512fb72c50a666d8e41c539e04`.

Nearpane compiles the reusable lyrics libraries, not LyricTileApp or its updater. One Host registry entry manages start, stop and ordering. The Host view owns the 0/104/192-point sidebar slot. The media helper is built from pinned source and packaged and signed with Nearpane. The lyrics cache belongs to the active Nearpane profile. The shared session lease arbitrates coexistence with prior standalone installations. The new optional module defaults to disabled; enable it in Nearpane Settings → Modules. No website changes.

Integration candidate only. The macOS workflow validates compilation, package and source tests; actual Host playback, pointer controls, repeated enable/disable, profile changes, display/full-screen behavior and signed distribution must be verified before publication. R4 dispatch failure remains separate. Prior standalone release artifacts are retained for rollback; standalone website is not used.
