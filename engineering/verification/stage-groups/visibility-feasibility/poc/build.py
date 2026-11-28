"""Build isolated developer probes; no production target, provisioning or distribution work."""
from pathlib import Path
import subprocess
import sys

SOURCE = Path(__file__).resolve().parent
TOOLS = ("Fixture", "Inspect", "Order", "Display")


def build(out):
    out.mkdir(parents=True, exist_ok=True)
    for tool in TOOLS:
        subprocess.run(["xcrun", "clang", "-fobjc-arc", "-Wall", "-Wextra",
                        "-Wno-unused-function", "-Wno-deprecated-declarations",
                        "-framework", "Cocoa", "-framework", "ApplicationServices",
                        str(SOURCE / (tool + ".m")), "-o", str(out / tool)], check=True)
        subprocess.run(["codesign", "--sign", "-", "--force", str(out / tool)], check=True)
        subprocess.run(["codesign", "--verify", "--strict", str(out / tool)], check=True)


if __name__ == "__main__":
    build(Path(sys.argv[1]))
