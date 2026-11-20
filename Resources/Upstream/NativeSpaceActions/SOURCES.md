# Native workspace action sources

InstantSpaceSwitcher v3.1 supplies the macOS 27 gesture encoding. Nearpane retains the serialized fluid gesture and velocity payload, removes the environment override and taps, constructs the whole gesture before posting, and validates the clicked display and system result. Smooth and reduced-motion profiles use separate explicit timings. Nonadjacent routing follows ISS’s ordered steps. Nearpane checks two actual current-space samples per intermediate step before issuing the next, and stops at the first mismatch. [ISS source at the pinned revision](https://github.com/jurplel/InstantSpaceSwitcher/tree/f7616e42651b1ed8d81625e3640eceed6efa8018/Sources/ISS)

yabai supplies the macOS 27 asynchronous single-window move operation. Nearpane extracts the single bridged branch, validates window identity, and checks actual window membership and siblings. [Move source at the pinned revision](https://github.com/asmvik/yabai/blob/b2dc8b4c892d74738a6e865d73048ed2dc3c9ed1/src/space_manager.c#L686-L695)

| Reviewed upstream file | SHA-256 of original |
| --- | --- |
| ISS.c | 4d6b3919b8123d38556a4d306f57aefd2b423a0a0af919170e38470f6f85837a |
| event_serialize.c | 9e9ba9dc332a0c75fa2bc47ab0b1f1ea5372b0397acc448ff1c33b4896a6f03c |
| space_manager.c | 7ac57b26df628352242aa218aaad34b3d82e2a928ecf68b7a588df907cef13a0 |

Both original MIT notices accompany this file. The unsupported-build, login-session, identity and readback checks live in the separate NearpaneSpaceAction helper.
