# Native workspace action sources

InstantSpaceSwitcher supplies the pinned macOS 27 fluid-gesture encoder. The P0 adapter uses three low-travel phases with the final fling and one companion per phase. The 26.6–26.7 form is separately constructed; installed capability stays off on unqualified builds. The pointer display, adjacent stable identities, event posting permission, terminal readback and delayed reversal are checked outside the wire codec. P0 disallows a second hop in the same request. No global event tap is installed and no Dock preference is modified. [Original encoder](https://github.com/jurplel/InstantSpaceSwitcher/tree/f7616e42651b1ed8d81625e3640eceed6efa8018/Sources/ISS) · [Reviewed ISS phase and direction implementation](https://github.com/jurplel/InstantSpaceSwitcher/blob/2b883a995d1c81fbc6d75704372a6a0b546bb1ff/Sources/ISS/ISS.c) · [noswoosh version and empty-desktop observations](https://github.com/mmathys/noswoosh/blob/14051ab58444c6868f603bee9a4daab12f9f6255/noswoosh.swift)

yabai supplies the macOS 27 asynchronous single-window move operation. Nearpane extracts the single bridged branch, validates window identity, and checks actual window membership and siblings. [Move source at the pinned revision](https://github.com/asmvik/yabai/blob/b2dc8b4c892d74738a6e865d73048ed2dc3c9ed1/src/space_manager.c#L686-L695)

| Reviewed upstream file | SHA-256 of original |
| --- | --- |
| ISS.c | 4d6b3919b8123d38556a4d306f57aefd2b423a0a0af919170e38470f6f85837a |
| event_serialize.c | 9e9ba9dc332a0c75fa2bc47ab0b1f1ea5372b0397acc448ff1c33b4896a6f03c |
| space_manager.c | 7ac57b26df628352242aa218aaad34b3d82e2a928ecf68b7a588df907cef13a0 |

Both original MIT notices accompany this file. The unsupported-build, login-session, identity and readback checks live in the separate NearpaneSpaceAction helper.
