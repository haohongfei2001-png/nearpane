# Nearpane — upstream source research entry

The single current product and architecture authority is
[the independent Stage Manager replacement decision](NEARPANE-INDEPENDENT-STAGE-DECISION.md).
The current fixed-source review is [Independent Spaces: source audit](INDEPENDENT-SPACES-SOURCE-AUDIT.md),
which preserves the stage-manager v1.9.2 mechanism baseline at `19e6e490bc91e65cef6a782075b5450e3159fd2d`
and includes the [v1.10.0 delta audit](INDEPENDENT-SPACES-SOURCE-AUDIT.md#v1100-delta-audit) at
`204d8de1ac2b682d147389c31a07b0a485ef9368` (release published 2026-11-26 17:23:02 UTC).
The new release changes shared observation, native-switcher timing and capture scheduling;
it does not change the hidden-Space bridge operations or turn the own-window launch probe into foreign-window evidence.

The [2026-11-21 v1.9.1 audit is preserved verbatim](archive/pre-independent-20261126/NEARPANE-STAGE-MANAGER-UPSTREAM-AUDIT.md).
Its Corner-default, automatic Corner fallback and in-process-only integration decisions are superseded.
They describe a historical proposal and must not select a current product backend or recovery route.
Nearpane now uses the independent hidden-Space path with its sealed AppKit worker and R4 interface;
failed scheduling restores owned windows and stops, without activating Apple-strip following or Corner.
