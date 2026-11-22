"""Historical ordinary-desktop fixture. Use the production Host witness on a naturally available desktop."""
import json
import sys


def main():
    print(json.dumps({
        "status": "BLOCKED", "reason": "ordinaryDesktopCreationFixtureArchived",
        "windowWrites": 0, "spaceWrites": 0, "quitRequests": 0,
        "nextEntry": "scripts/acceptance/window-engine/host/build-overview-witness.sh",
    }))
    return 2


if __name__ == "__main__":
    sys.exit(main())
