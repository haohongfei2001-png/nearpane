#!/usr/bin/env python3
"""Network-free regression checks for the locked source boundary."""
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import tarfile
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("domain_resolver", Path(__file__).with_name("prepare-domains.py"))
resolver = importlib.util.module_from_spec(spec)
spec.loader.exec_module(resolver)
COMMIT = "a" * 40
FILES = {"Sources/one.swift": b"first", "Sources/two.swift": b"second"}


def fixture():
    hashes = {p: hashlib.sha256(b).hexdigest() for p, b in FILES.items()}
    return dict(repository="example/Upstream", commit=COMMIT, treeSHA256=resolver.tree_hash(hashes),
                sources=["Sources"], hostSources=[], notices=[], files=hashes)


def archive(files, commit=COMMIT):
    data = io.BytesIO()
    with tarfile.open(fileobj=data, mode="w:gz", format=tarfile.PAX_FORMAT, pax_headers={"comment": commit}) as tgz:
        for path, value in files.items():
            entry = tarfile.TarInfo("Upstream-" + COMMIT + "/" + path)
            entry.size = len(value)
            tgz.addfile(entry, io.BytesIO(value))
    data.seek(0)
    return data


class DependencyTests(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory(dir=Path(__file__).resolve().parents[1] / "build")
        self.addCleanup(self.scratch.cleanup)
        self.cache = Path(self.scratch.name)
        self.pin = fixture()

    def test_wrong_commit_and_incomplete_or_tampered_stream_are_never_published(self):
        for payload in (archive(FILES, "b"*40), archive({"Sources/one.swift": b"first"}),
                        archive(dict(FILES, **{"Sources/two.swift": b"altered"}))):
            with self.subTest(), patch.object(resolver, "remote", return_value=payload):
                with self.assertRaises(resolver.DependencyError):
                    resolver.prepare(self.cache, self.pin, False)
                self.assertEqual(list(self.cache.iterdir()), [])

    def test_download_failure_and_empty_offline_cache_fail_closed(self):
        with patch.object(resolver, "remote", side_effect=OSError("network unavailable")) as fetch:
            with self.assertRaisesRegex(resolver.DependencyError, "Offline cache missing"):
                resolver.prepare(self.cache, self.pin, True)
            fetch.assert_not_called()
            with self.assertRaisesRegex(resolver.DependencyError, COMMIT):
                resolver.prepare(self.cache, self.pin, False)
        self.assertEqual(list(self.cache.iterdir()), [])

    def test_cache_reuse_checks_every_byte_even_without_network(self):
        with patch.object(resolver, "remote", return_value=archive(FILES)):
            dest = resolver.prepare(self.cache, self.pin, False)
        with patch.object(resolver, "remote", side_effect=AssertionError("offline network use")):
            self.assertEqual(resolver.prepare(self.cache, self.pin, True), dest)
            (dest / "Sources/one.swift").write_bytes(b"changed")
            with self.assertRaisesRegex(resolver.DependencyError, "checksum mismatch"):
                resolver.prepare(self.cache, self.pin, True)

    def test_unlisted_compiler_input_or_link_invalidates_cache(self):
        with patch.object(resolver, "remote", return_value=archive(FILES)):
            dest = resolver.prepare(self.cache, self.pin, False)
        extra = dest / "Sources/unlisted.swift"
        extra.write_bytes(b"extra")
        with self.assertRaisesRegex(resolver.DependencyError, "Unexpected cache file"):
            resolver.verify(dest, self.pin)
        extra.unlink()
        (dest / "alias").symlink_to(dest / "Sources", target_is_directory=True)
        with self.assertRaisesRegex(resolver.DependencyError, "symlink"):
            resolver.verify(dest, self.pin)

    def test_checked_in_lock_is_self_consistent(self):
        lock = json.loads(resolver.LOCK.read_text())
        for pin in lock["domains"].values():
            resolver.validate(pin)
            bad = dict(pin, treeSHA256="f"*64)
            with self.assertRaisesRegex(resolver.DependencyError, "inventory SHA"):
                resolver.validate(bad)

    def test_voice_bridge_refuses_redirected_upstream_inputs(self):
        domain = self.cache / resolver.key(self.pin) / "Sources/SaytileKit"
        domain.mkdir(parents=True)
        resolver.voice_bindings(self.cache, self.pin)
        link = self.cache / ("voice-" + resolver.key(self.pin)) / "Upstream"
        self.assertEqual(link.resolve(strict=True), domain)
        link.unlink()
        link.symlink_to(self.cache)
        with self.assertRaisesRegex(resolver.DependencyError, "Invalid SaytileKit bridge"):
            resolver.voice_bindings(self.cache, self.pin)


if __name__ == "__main__":
    (Path(__file__).resolve().parents[1] / "build").mkdir(exist_ok=True)
    unittest.main()
