# Native Space trial entry

From the checkout, use a fresh output directory for each run. A run without a lease reads the installed Host, signatures, permission probe, sidebar AX controls and WindowServer inventory, writes its refusal and issues zero inputs.

```sh
scripts/acceptance/native-spaces/space-trials.sh build/verification/native12/space-preflight
```

Each eligible ordinary test desktop needs its own private `create-intent.json` and `created.json` from the native provisioning fixture in `build/verification/secondary-route-followup/<UUID>/provision/`. The receipts must belong to this boot, form a continuous chain and still be within their fifteen-minute lifetime. They identify the newly created desktop by ID and UUID. The original desktop, any unrelated fullscreen desktop and any existing personal desktop are outside the lease. A lease covers a contiguous range on one physical display. The single-display provisioning fixture preserves the full order, identities and fullscreen types. It requires its authorized ordinary source to be last before adding a desktop.

The following shows the runner arguments. Entries in angle brackets refer to positive evidence already produced by the fixture. The runner discovers neither targets nor grants by enumerating personal desktops. D01 accepts two created desktops with zero fixture windows at preparation. For S02/R01 use three, with an owned, focused Field Notes window in A, an owned window in B and C empty. Run fixtures with umask 077. Per-process receipts must come from the checked-in Field Notes fixture in its temporary test kit and name its PID, birth, session and CG window numbers. The driver independently validates each process and WindowServer membership.

```text
scripts/acceptance/native-spaces/space-trials.sh \
  --created <A/created.json> --created <B/created.json> --created <C/created.json> \
  --fixture <A-id> <kit/session/windows.json> --fixture <B-id> <kit/session/windows.json> \
  <fresh-scope-directory>
scripts/acceptance/native-spaces/space-trials.sh --scope <absolute-scope.json> <fresh-trial-output>
scripts/acceptance/native-spaces/space-trials.sh --observe-system 20 --scope <absolute-scope.json> <fresh-S03-output>
```

The action runner presses exact AX controls in the installed product. It records each attempt before and after the press, counts all errors and reads the final Space and sidebar selection independently. S02 includes 50 directed selections across A/B/C. The R01 subset issues twenty bursts, each with three to five selections less than 250 ms apart, and checks the final selected identity. The last target differs from the starting desktop. A success in this subset still leaves window closure during an in-flight request outstanding. The S03 reader never issues input. It records system current, order and sidebar agreement when a separate, scoped system operator performs a change. Its readback needs a separate operator and return receipt for full S03 acceptance.

Physical input, unverifiable focus, unleased membership, disappeared windows, changed system state or failed readback stop further dispatch. A normal sequence returns to its initial leased desktop and checks the original fixture focus. On an ambiguous action, the runner records whether it returned and preserves the cause. It does not replay the action or force a return against a changed user desktop. Provisioning and removing test desktops remain separate operations with their own creation, occupancy and cleanup receipts.

Offline guard tests run with `python3 scripts/acceptance/native-spaces/test_space_trials.py`.
