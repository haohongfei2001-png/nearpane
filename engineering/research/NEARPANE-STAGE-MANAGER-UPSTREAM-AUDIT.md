# Nearpane — upstream source research entry

The single current product and architecture authority is
[the independent Stage Manager replacement decision](NEARPANE-INDEPENDENT-STAGE-DECISION.md).
The current fixed-source review is [Independent Spaces: source audit](INDEPENDENT-SPACES-SOURCE-AUDIT.md),
which examines stage-manager v1.9.2 at `19e6e490bc91e65cef6a782075b5450e3159fd2d` and the other referenced implementations.

The [2026-11-21 v1.9.1 audit is preserved verbatim](archive/pre-independent-20261126/NEARPANE-STAGE-MANAGER-UPSTREAM-AUDIT.md).
Its Corner-default, automatic Corner fallback and in-process-only integration decisions are superseded.
They describe a historical proposal and must not select a current product backend or recovery route.
Nearpane now uses the independent hidden-Space path with its sealed AppKit worker and R4 interface;
failed scheduling restores owned windows and stops, without activating Apple-strip following or Corner.
