# b309067f: compile failure before window experiments

Run [45725938658](https://github.com/haohongfei2001-png/nearpane/actions/runs/45725938658),
source `b309067f6e94e81a18600db938b03e1279cfc1d2`.

The macOS C compiler rejected the two historical installed-fixture callers in
`src/spaces/installed-fixture.inc` at lines 319 and 465: the updated foreign-focus
reader takes four arguments, but those callers still supplied three. This blocked
the Rust native build, worker archive and Swift wrapper's prerequisite engine build.
The new Swift source and tests did not reach compilation or execution on this run.

The full, R4-fast and diagnostics jobs failed before any new controlled-window
experiment. Product R4, Finder desktop structure, yellow-minimize migration and
all other physical behavior were **NOT_RUN**. No complete candidate was produced.
The Python evidence and native-diagnostic unit checks passed; they do not change
the failed build status.

`source-summary.json` is the byte-for-byte full-job receipt. `provenance.json`
records its hash and both full/fast artifact identities. The source wrapper's
`swift: FAIL` describes its failed prerequisite, not an observed Swift language
error. The complete original compiler logs remain in the linked run's artifacts.
