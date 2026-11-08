# Nearpane P1 — Read-only macOS Spaces probe

This folder contains an experimental probe used for the P1 platform-capability spike. It is not production code and is not a supported macOS API wrapper.

## What it reads

- Public display metadata through AppKit / Quartz Display Services.
- The Mission Control separate-Spaces preference through `NSScreen.screensHaveSeparateSpaces`.
- Window metadata through `CGWindowListCopyWindowInfo`.
- SkyLight managed display scopes and window-to-Space membership through dynamically resolved private symbols.

The probe matches SkyLight display identifiers against public display UUIDs. It records only anonymous window ordinals in its output, but the raw output still contains display UUIDs, display names, and window geometry.

## What it does not do

- Does not capture screen or window pixels.
- Does not switch Spaces.
- Does not activate windows or change focus.
- Does not request Accessibility or Screen Recording permissions.
- Does not modify Mission Control settings.
- Does not inject into other processes.

The permission preflight checks are read-only.

## Build and run

Tested on macOS 27.0 (Build 26A428), ARM64:

```sh
swiftc -module-cache-path /tmp/nearpane-module-cache \
  -o /tmp/nearpane-spaces-probe spaces-mapping-probe.swift
/tmp/nearpane-spaces-probe > spaces-mapping-raw.json
```

Keep raw output local. Do not upload raw output to a public repository because it contains display identifiers and live window geometry. The repository includes only the sanitized evidence summary under `evidence/`.

## Private API warning

The probe dynamically resolves:

- `SLSMainConnectionID`
- `SLSCopyManagedDisplaySpaces`
- `SLSCopySpacesForWindows`

These are private, undocumented, version-sensitive interfaces. Symbol presence and a successful read-only call on one macOS build do not establish stable ABI, distribution approval, or production readiness.

See `docs/engineering/P1-READONLY-BASELINE-20261109.md` for the tested build, observations, limits, and next validation gates.
