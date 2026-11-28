# 34f target: two distinct precondition attempts; original settings restored

Both attempts use exactclean source34f37360144eb8e339ac81b1f901536f31853ad6 and its complete release application on the target macOS27.0 /26A428 /arm64 /SIP enabled. They are not cloud results and neither reached an R4 click.

## Ordinary desktop reached while native Stage Manager was enabled

The native LaunchServices application-opening entry established ordinary desktop4. The first runtime then positively observed Apple Stage Manager enabled and returned BLOCKED/appleStageManagerEnabled with0 window writes. Product startup returned BLOCKED/fixtureGroupsNotReady, actualR4Inputs0. Shutdown released=true in2.653ms; two complete physical observations confirm fixture windows121684/121686/121690 visible at originalhome4 with frames preserved. Both fixtures exited0.

## Native Stage Manager temporarily off, but desktop no longer ordinary at controller preflight

The second setup saved the original effective preference, temporarily changed only GloballyEnabled fromtrue tofalse using the existing native preference helper, confirmed that value, and positively read ordinary desktop4 before starting the unified runtime. At the later controller preflight the current Space was again7015/type4, with ordinaryCurrentCount0. The controller correctly returned BLOCKED/ordinaryCurrentDesktopCountNotOne with0 writes; product returned BLOCKED/fixtureBaselineUnavailable and0 actual inputs. The record does not establish why the active Space changed. No R4 input was retried or qualifying guard bypassed.

After positive engine/product cleanup and normal fixture exits, the setup restored the original Stage Manager preference totrue and used the existing live-AppKit activation helper to return to the original process. Final raw setup result confirms **originalStageManagerRestored=true, originalDesktopRestored=true, originalFrontRestored=true**. The current Space was7015/type4 again. This is restoration of the original desktop and foreground process, not an independently bound original-window focus claim.

All originals have exact byte counts and SHA-256 hashes in [provenance.json](provenance.json). Unrelated user-window content, screenshots and the original foreground application's identifying metadata are omitted. These BLOCKED results must remain separate from formal R4 latency or end-to-end success.
