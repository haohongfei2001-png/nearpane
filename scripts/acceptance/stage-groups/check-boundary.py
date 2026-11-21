"""Inspect the linked production worker and the product entry points that previously exposed native Space writes."""
import json
from pathlib import Path
import subprocess
import sys

helper = Path(sys.argv[1]).resolve(strict=True)
symbols = subprocess.check_output(["nm", "-a", helper], text=True)
blocked = ("_NPSendAdjacentSwipe", "_NPSendDiagnosticAdjacentSwipe", "_NPCreateWindowMove",
           "_NPSubmitWindowMove", "_NPDockInstalledProtocol", "_CGEventPostToPid")
leaks = [name for name in blocked if name in symbols]
root = Path(__file__).resolve().parents[3]
ui = {"Sources/NearpaneHost/NearpaneApp.swift": ["showSpaceMenu", "NativeSpaceMenu.request"],
      "Sources/NearpaneUI/DesktopSurface.swift": ["NativeSpaceMenu", "navigation.move(", "navigation.select(", "NativeWindowDropTarget"],
      "Sources/NearpaneUI/NativeSpaceNavigator.swift": ["NativeWindowDropTarget", "canMove"]}
routes = [path + " " + term for path, terms in ui.items() for term in terms if term in (root / path).read_text()]
read_only_probe = subprocess.check_output([helper, "--self-check"], text=True).strip()
good = "no action issued" in read_only_probe and "_NPReadInventory" in symbols and not (leaks or routes)
print(json.dumps(dict(status="PASS" if good else "FAIL", removedSymbols=blocked, linkedWriteSymbols=leaks,
                      productionRouteHits=routes, retainedReadOnlyInventory="_NPReadInventory" in symbols, probe=read_only_probe)))
if not good:
    sys.exit(1)
