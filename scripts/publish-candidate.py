"""Publish a verified Nearpane candidate on the destination volume (macOS)."""
import ctypes
import fcntl
import hashlib
import json
import os
from pathlib import Path
import plistlib
import stat
import subprocess
import sys
import tempfile


def rename(source, target, flags):
    # Darwin sys/stdio.h: SWAP exchanges two entries, EXCL requires an unused name.
    call = ctypes.CDLL(None, use_errno=True).renamex_np
    call.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint]
    if call(os.fsencode(source), os.fsencode(target), flags) != 0:
        error = ctypes.get_errno()
        raise OSError(error, os.strerror(error), str(target))


def identity(path):
    entry = path.lstat()
    if not stat.S_ISDIR(entry.st_mode) or entry.st_uid != os.getuid():
        raise ValueError(f"Expected an owned application directory at {path}")
    return entry.st_dev, entry.st_ino


def verify_alpha(app):
    key = identity(app)
    contents = app / "Contents"
    info = plistlib.loads((contents / "Info.plist").read_bytes())
    if (info.get("CFBundleIdentifier") != "com.holdsnow.nearpane.alpha"
            or info.get("CFBundleExecutable") != "NearpaneHost"
            or info.get("LSMultipleInstancesProhibited") is not True
            or not (contents / "Resources/Profile/profile-migration.py").is_file()
            or not (contents / "Helpers/NearpaneDesktopReader").is_file()):
        raise ValueError(f"Refusing to replace an unrecognized application: {app}")
    subprocess.run(["/usr/bin/codesign", "--verify", "--strict", "--deep",
                    "-R=identifier \"com.holdsnow.nearpane.alpha\"", str(app)], check=True)
    return key


def require_stopped(*bundles):
    # comm is the executable, with no documents or command-line arguments.
    rows = subprocess.check_output(["/bin/ps", "-U", str(os.getuid()), "-ww", "-o", "comm="],
                                   text=True).splitlines()
    if not any(line.strip().startswith("/") for line in rows):
        raise RuntimeError("Could not verify the application's running state")
    prefixes = tuple(str(path) + "/" for path in bundles)
    for line in rows:
        if line.strip().startswith(prefixes):
            raise RuntimeError("Quit Nearpane and its helpers before installing this update")


def publish(candidate, target, receipt):
    if candidate.is_symlink() or target.is_symlink() or target.parent.is_symlink():
        raise ValueError("Refusing a symlinked application or installation directory")
    stage = candidate.parent.resolve(strict=True)
    delivery = target.parent.resolve(strict=True)
    if stage.parent != delivery or not stage.name.startswith(".nearpane-stage.") or candidate.name != target.name:
        raise ValueError("Candidate must be staged in the installation directory")
    candidate, target = stage / candidate.name, delivery / target.name
    release = (stage / "package.json").read_bytes()
    report = json.loads(release)
    if (report.get("bundle") != "com.holdsnow.nearpane.alpha"
            or report["binaries"]["MacOS/NearpaneHost"]["sha256"]
            != hashlib.sha256((candidate / "Contents/MacOS/NearpaneHost").read_bytes()).hexdigest()):
        raise ValueError("Staged package does not match its verification receipt")
    incoming = verify_alpha(candidate)
    receipt.parent.mkdir(parents=True, exist_ok=True)
    directory = os.open(delivery, os.O_RDONLY | os.O_DIRECTORY)
    try:
        fcntl.flock(directory, fcntl.LOCK_EX | fcntl.LOCK_NB)
        if receipt.is_symlink() or (receipt.exists() and not receipt.is_file()):
            raise ValueError(f"Invalid receipt destination: {receipt}")
        previous = verify_alpha(target) if os.path.lexists(target) else None
        with tempfile.NamedTemporaryFile(prefix=".nearpane-receipt.", dir=receipt.parent, delete=False) as out:
            temp = Path(out.name)
        try:
            with temp.open("wb") as out:
                out.write(release)
                out.flush()
                os.fsync(out.fileno())
            require_stopped(candidate, target)
            # Retain both entries if interrupted between publication and rollback.
            marker = stage / "keep-for-recovery"
            marker.touch(exist_ok=False)
            try:
                rename(candidate, target, 2 if previous else 4)
            except OSError:
                marker.unlink()
                raise
            try:
                if identity(target) != incoming or (previous and identity(candidate) != previous):
                    raise RuntimeError("Installation directory changed during publication")
                if previous:
                    require_stopped(candidate)
                os.replace(temp, receipt)
            except BaseException:
                if identity(target) != incoming or (previous and identity(candidate) != previous):
                    raise RuntimeError(f"Unexpected replacement; original staging retained at {stage}")
                require_stopped(target)
                rename(target, candidate, 2 if previous else 4)
                marker.unlink()
                raise
            marker.unlink()
        finally:
            temp.unlink(missing_ok=True)
    finally:
        os.close(directory)


if __name__ == "__main__":
    try:
        publish(*(Path(arg) for arg in sys.argv[1:]))
    except (OSError, RuntimeError, ValueError, KeyError, subprocess.CalledProcessError) as error:
        sys.exit(str(error))
