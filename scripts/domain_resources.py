"""Resource inventory and provenance for the two embedded tool engines."""
import hashlib


def source_receipt(pin):
    fields = ("repository", "commit", "treeSHA256", "notices", "releaseTag", "upstreamBuild",
              "captureReadiness", "draftWitness")
    return {key: pin[key] for key in fields if key in pin}


def verify_resources(root, name, pin):
    module, bundle = {"saytile": ("SaytileKit", "Nearpane_SaytileKit"),
                      "riftlet": ("RiftletAdapters", "Riftlet_RiftletAdapters")}[name]
    prefix = f"Sources/{module}/Resources/"
    folder = root.absolute() / (bundle + ".bundle") / "Contents/Resources"
    expected = {path[len(prefix):]: digest for path, digest in pin["files"].items() if path.startswith(prefix)}
    entries = list(folder.rglob("*"))
    if not expected or any(path.is_symlink() for path in entries) or folder.resolve() != folder:
        raise ValueError(f"Invalid {name} resource directory")
    actual = {path.relative_to(folder).as_posix() for path in entries if path.is_file()}
    if actual != set(expected):
        raise ValueError(f"{name} resource inventory differs from the lock: {sorted(actual ^ set(expected))}")
    for path, digest in expected.items():
        if hashlib.sha256((folder / path).read_bytes()).hexdigest() != digest:
            raise ValueError(f"Incorrect bundled {name} resource: {path}")
