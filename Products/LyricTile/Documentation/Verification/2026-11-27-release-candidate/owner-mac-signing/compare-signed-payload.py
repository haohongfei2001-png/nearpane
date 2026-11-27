#!/usr/bin/env python3
"""Compare an original LyricTile CI49 app with its release-signing copy.

Python 3.9+, standard library only; read-only inputs. This does not validate
certificates, entitlements, Gatekeeper or notarization: run verify-release.py too.
Mach-O layouts follow Apple's cctools include/mach-o/{loader,fat}.h. The bundle
ticket path follows Apple's Security/libsecurity_codesigning/lib/notarization.cpp.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import stat
import struct
import sys
import uuid

INFO_VALUES = {
    "SUFeedURL": "https://raw.githubusercontent.com/haohongfei2001-png/nearpane/refs/heads/codex/lyrictile-standalone-20261126/Products/LyricTile/Updates/appcast.xml",
    "SUPublicEDKey": "NjwCt0hsJ9Ps97gwa1ZQvHfaVkr69TN0JIjNi7E522w=",
    "SUVerifyUpdateBeforeExtraction": True,
    "LyricTileDistributionChannel": "release",
}
SPARKLE = "Contents/Frameworks/Sparkle.framework/Versions/B"
SEALS = {
    "Contents/_CodeSignature/CodeResources",
    "Contents/Resources/MediaRemote/MediaRemoteAdapter.framework/Versions/A/_CodeSignature/CodeResources",
    SPARKLE + "/_CodeSignature/CodeResources",
    SPARKLE + "/Updater.app/Contents/_CodeSignature/CodeResources",
    SPARKLE + "/XPCServices/Downloader.xpc/Contents/_CodeSignature/CodeResources",
    SPARKLE + "/XPCServices/Installer.xpc/Contents/_CodeSignature/CodeResources",
}
TICKET = "Contents/CodeResources"
SIGNATURE_DIRECTORIES = {str(Path(p).parent) for p in SEALS}
THIN = {b"\xce\xfa\xed\xfe": ("<", False), b"\xcf\xfa\xed\xfe": ("<", True),
        b"\xfe\xed\xfa\xce": (">", False), b"\xfe\xed\xfa\xcf": (">", True)}
FAT = {b"\xca\xfe\xba\xbe": (">", False), b"\xca\xfe\xba\xbf": (">", True),
       b"\xbe\xba\xfe\xca": ("<", False), b"\xbf\xba\xfe\xca": ("<", True)}
ZERO_FILL = {0x01, 0x0C, 0x12}


def sha(data):
    return hashlib.sha256(data).hexdigest()


def require(condition, message):
    if not condition:
        raise ValueError(message)


def bounded(data, offset, size, label):
    require(offset >= 0 and size >= 0 and offset <= len(data) and size <= len(data) - offset,
            "Out-of-range " + label)
    return data[offset:offset + size]


def cstring(data):
    return data.split(b"\0", 1)[0].decode("ascii", "strict")


def thin_slice(data):
    require(data[:4] in THIN, "Unsupported Mach-O slice magic")
    endian, wide = THIN[data[:4]]
    header_size = 32 if wide else 28
    bounded(data, 0, header_size, "Mach-O header")
    cpu, subtype, filetype, ncmds, command_bytes, flags = struct.unpack_from(endian + "iiIIII", data, 4)
    require(0 < ncmds <= 65536, "Invalid Mach-O load-command count")
    command_end = header_size + command_bytes
    bounded(data, header_size, command_bytes, "load commands")
    cursor = header_size
    signatures, uuids, sections, links = [], [], [], []
    normalized = bytearray(data)
    for _ in range(ncmds):
        bounded(data, cursor, 8, "load-command header")
        cmd, size = struct.unpack_from(endian + "II", data, cursor)
        require(size >= 8 and size % 4 == 0 and cursor + size <= command_end,
                "Invalid Mach-O load-command length")
        if cmd == 0x1B:  # LC_UUID
            require(size == 24, "Invalid LC_UUID length")
            uuids.append(str(uuid.UUID(bytes=bounded(data, cursor + 8, 16, "UUID"))))
        elif cmd == 0x1D:  # LC_CODE_SIGNATURE / linkedit_data_command
            require(size == 16, "Invalid LC_CODE_SIGNATURE length")
            offset, length = struct.unpack_from(endian + "II", data, cursor + 8)
            bounded(data, offset, length, "code signature")
            require(length > 0 and offset >= command_end, "Invalid code-signature location")
            signatures.append({"offset": offset, "size": length, "sha256": sha(data[offset:offset + length])})
            # Keep dataoff and the entire other load-command content unchanged.
            normalized[cursor + 12:cursor + 16] = b"\0" * 4
        elif cmd in (0x01, 0x19):  # LC_SEGMENT / LC_SEGMENT_64
            seg_wide = cmd == 0x19
            base_size, section_size = (72, 80) if seg_wide else (56, 68)
            require(size >= base_size, "Truncated segment command")
            name = cstring(data[cursor + 8:cursor + 24])
            fmt = "QQQQiiII" if seg_wide else "IIIIiiII"
            vmaddr, vmsize, fileoff, filesize, maxprot, initprot, count, segflags = struct.unpack_from(endian + fmt, data, cursor + 24)
            require(size == base_size + count * section_size, "Segment/section count mismatch")
            bounded(data, fileoff, filesize, "segment file contents")
            if name == "__LINKEDIT":
                require(count == 0, "Unexpected sections inside __LINKEDIT")
                links.append({"vmaddr": vmaddr, "vmsize": vmsize, "fileoff": fileoff, "filesize": filesize})
                word = 8 if seg_wide else 4
                for field in (cursor + 24 + word, cursor + 24 + 3 * word):
                    normalized[field:field + word] = b"\0" * word
            for index in range(count):
                at = cursor + base_size + index * section_size
                section_name = cstring(data[at:at + 16])
                segment_name = cstring(data[at + 16:at + 32])
                if seg_wide:
                    address, length, offset, alignment, reloff, nreloc, section_flags, r1, r2, r3 = struct.unpack_from(endian + "QQIIIIIIII", data, at + 32)
                else:
                    address, length, offset, alignment, reloff, nreloc, section_flags, r1, r2 = struct.unpack_from(endian + "IIIIIIIII", data, at + 32)
                    r3 = None
                zero_fill = (section_flags & 0xFF) in ZERO_FILL
                content = None if zero_fill else bounded(data, offset, length, "section contents")
                sections.append({"segment": segment_name, "section": section_name, "address": address,
                    "size": length, "offset": offset, "alignment": alignment, "flags": section_flags,
                    "relocationOffset": reloff, "relocationCount": nreloc, "reserved": [r1, r2, r3],
                    "zeroFill": zero_fill, "sha256": None if content is None else sha(content)})
        cursor += size
    require(cursor == command_end, "Unused or missing load-command bytes")
    require(len(uuids) == 1, "Expected exactly one LC_UUID per signed slice")
    require(len(signatures) == 1 and len(links) == 1, "Expected one code signature and __LINKEDIT per signed slice")
    signature, link = signatures[0], links[0]
    signature_end = signature["offset"] + signature["size"]
    require(link["fileoff"] <= signature["offset"] and link["fileoff"] + link["filesize"] == signature_end,
            "Code signature is not the end of __LINKEDIT")
    require(link["vmsize"] >= link["filesize"], "Invalid __LINKEDIT VM size")
    require(not any(data[signature_end:]), "Unexplained nonzero bytes after code signature")
    for section in sections:
        if not section["zeroFill"]:
            require(section["offset"] + section["size"] <= signature["offset"], "Section overlaps signature")
    return {"cpuType": cpu, "cpuSubtype": subtype, "bits": 64 if wide else 32, "byteOrder": endian,
        "fileType": filetype, "flags": flags, "uuid": uuids[0], "sections": sections,
        "signature": signature, "linkedit": link,
        "normalizedUnsignedPrefixSHA256": sha(normalized[:signature["offset"]]),
        "normalizedUnsignedPrefixBytes": signature["offset"],
        "zeroPaddingAfterSignatureBytes": len(data) - signature_end}


def macho(data):
    if data[:4] in THIN:
        return {"container": "thin", "slices": [thin_slice(data)]}
    if data[:4] not in FAT:
        return None
    endian, wide = FAT[data[:4]]
    bounded(data, 0, 8, "fat header")
    count = struct.unpack_from(endian + "I", data, 4)[0]
    require(0 < count <= 64, "Invalid fat architecture count")
    entry_size = 32 if wide else 20
    header_end = 8 + count * entry_size
    bounded(data, 8, count * entry_size, "fat architecture table")
    slices, ranges, identities = [], [], set()
    for index in range(count):
        at = 8 + index * entry_size
        if wide:
            cpu, subtype, offset, size, alignment, reserved = struct.unpack_from(endian + "iiQQII", data, at)
        else:
            cpu, subtype, offset, size, alignment = struct.unpack_from(endian + "iiIII", data, at)
            reserved = None
        require(alignment <= 30 and offset >= header_end and offset % (1 << alignment) == 0,
                "Invalid fat slice alignment/location")
        require((cpu, subtype) not in identities, "Duplicate fat architecture")
        identities.add((cpu, subtype))
        one = thin_slice(bounded(data, offset, size, "fat slice"))
        require(one["cpuType"] == cpu and one["cpuSubtype"] == subtype, "Fat/slice architecture mismatch")
        one["containerOffset"] = offset
        one["containerSize"] = size
        one["containerAlignment"] = alignment
        one["containerReserved"] = reserved
        slices.append(one)
        ranges.append((offset, offset + size))
    previous = header_end
    for start, end in sorted(ranges):
        require(start >= previous, "Overlapping fat slices")
        require(not any(data[previous:start]), "Nonzero fat container padding")
        previous = end
    require(not any(data[previous:]), "Nonzero fat container trailer")
    return {"container": "fat64" if wide else "fat32", "byteOrder": endian, "slices": slices}


def compare_macho(before, after):
    reasons = []
    if before["container"] != after["container"] or before.get("byteOrder") != after.get("byteOrder"):
        reasons.append("Mach-O container format changed")
    a, b = before["slices"], after["slices"]
    if [(x["cpuType"], x["cpuSubtype"]) for x in a] != [(x["cpuType"], x["cpuSubtype"]) for x in b]:
        return reasons + ["Architecture list/order changed"]
    for old, new in zip(a, b):
        for key in ("bits", "byteOrder", "fileType", "flags", "uuid", "sections",
                    "normalizedUnsignedPrefixBytes", "normalizedUnsignedPrefixSHA256",
                    "containerAlignment", "containerReserved"):
            if old.get(key) != new.get(key):
                reasons.append("Architecture %s:%s changed %s" % (old["cpuType"], old["cpuSubtype"], key))
        # filesize is already constrained to end at the signature. Permit a VM
        # size change only if a common power-of-two rounding fits both files.
        ol, nl = old["linkedit"], new["linkedit"]
        if ol["vmsize"] != nl["vmsize"]:
            compatible = any(((ol["filesize"] + (1 << power) - 1) // (1 << power)) * (1 << power) == ol["vmsize"]
                and ((nl["filesize"] + (1 << power) - 1) // (1 << power)) * (1 << power) == nl["vmsize"]
                for power in range(31))
            if not compatible:
                reasons.append("__LINKEDIT VM-size change is not consistent signature-size rounding")
    return reasons


def inventory(root):
    result = {}
    for parent, directories, files in os.walk(str(root), followlinks=False):
        for name in sorted(directories + files):
            path = Path(parent) / name
            relative = path.relative_to(root).as_posix()
            mode = path.lstat().st_mode
            record = {"mode": oct(stat.S_IMODE(mode))}
            if stat.S_ISLNK(mode):
                target = os.readlink(str(path))
                record.update(kind="symlink", target=target, sha256=sha(os.fsencode(target)))
            elif stat.S_ISDIR(mode):
                record.update(kind="directory")
            elif stat.S_ISREG(mode):
                data = path.read_bytes()
                record.update(kind="file", bytes=len(data), sha256=sha(data))
            else:
                raise ValueError("Unsupported filesystem node: " + relative)
            result[relative] = record
        directories[:] = [name for name in directories if not (Path(parent) / name).is_symlink()]
    return result


def compare_apps(before_root, after_root):
    before, after = inventory(before_root), inventory(after_root)
    files, failures, changed, macho_count, slice_count = [], [], [], 0, 0
    for path in sorted(set(before) | set(after)):
        old, new = before.get(path), after.get(path)
        row = {"path": path, "before": old, "after": new, "passed": True}
        reasons = []
        if old != new:
            changed.append(path)
        if path in SEALS or path == TICKET:
            row["comparison"] = "allowlisted resource seal" if path in SEALS else "allowlisted root notarization ticket"
            if new is None or new["kind"] != "file" or (old is not None and old["kind"] != "file"):
                reasons.append("Signing artifact is absent or not a regular file")
        elif path in SIGNATURE_DIRECTORIES and old is None and new and new["kind"] == "directory":
            row["comparison"] = "allowlisted signing directory creation"
        elif old is None or new is None:
            reasons.append("Unallowlisted added/removed path")
        elif old["kind"] != new["kind"] or old["mode"] != new["mode"]:
            reasons.append("Node type or permissions changed")
        elif old["kind"] != "file":
            row["comparison"] = "exact node metadata"
            if old != new:
                reasons.append("Directory metadata or symbolic-link target changed")
        elif path == "Contents/Info.plist":
            first = plistlib.loads((before_root / path).read_bytes())
            second = plistlib.loads((after_root / path).read_bytes())
            keys = [key for key in set(first) | set(second) if first.get(key) != second.get(key)
                    or (key in first) != (key in second) or type(first.get(key)) is not type(second.get(key))]
            row["comparison"] = "exact plist values except four pinned release keys"
            row["changedPlistValues"] = {key: {"before": first.get(key), "after": second.get(key)} for key in sorted(keys)}
            for key in keys:
                if key not in INFO_VALUES or second.get(key) != INFO_VALUES[key] or type(second.get(key)) is not type(INFO_VALUES[key]):
                    reasons.append("Unallowlisted Info.plist change: " + key)
        else:
            first_data, second_data = (before_root / path).read_bytes(), (after_root / path).read_bytes()
            first_macho, second_macho = macho(first_data), macho(second_data)
            if first_macho is not None or second_macho is not None:
                row["comparison"] = "all-architecture Mach-O UUID, sections and normalized unsigned bytes"
                row["beforeMachO"], row["afterMachO"] = first_macho, second_macho
                macho_count += 1
                slice_count += len(first_macho["slices"]) if first_macho else 0
                if first_macho is None or second_macho is None:
                    reasons.append("Mach-O/non-Mach-O type changed")
                else:
                    reasons.extend(compare_macho(first_macho, second_macho))
            else:
                row["comparison"] = "exact regular-file SHA256"
                if old["sha256"] != new["sha256"]:
                    reasons.append("Non-signature resource contents changed")
        row["passed"] = not reasons
        row["failures"] = reasons
        failures.extend({"path": path, "reason": reason} for reason in reasons)
        files.append(row)
    return {"schemaVersion": 1, "status": "FAIL" if failures else "PASS",
        "beforeApp": str(before_root), "afterApp": str(after_root),
        "toolSHA256": sha(Path(__file__).read_bytes()),
        "allowedInfoValues": INFO_VALUES, "allowlistedResourceSealPaths": sorted(SEALS),
        "allowlistedNotarizationTicketPath": TICKET,
        "comparedPaths": len(files), "changedPaths": changed, "machOFiles": macho_count,
        "machOArchitectureSlices": slice_count, "failures": failures, "files": files,
        "normalization": ["Only LC_CODE_SIGNATURE.datasize and __LINKEDIT.vmsize/filesize are normalized inside each unsigned prefix.",
            "LC_CODE_SIGNATURE.dataoff, other load commands, every unsigned byte including dyld fixups/symbol data and all section descriptors/content remain exact.",
            "Only zero padding may follow a slice signature or fill fat container gaps; architecture order/alignment and every UUID remain exact.",
            "Zero-fill sections retain exact descriptors but have no file-content hash."],
        "limits": ["This proves the compared payload relationship, not certificate trust, preserved entitlements or notarization. Use codesign/stapler/Gatekeeper and verify-release.py separately.",
            "Filesystem xattrs, ownership and modification dates are outside this content comparison; permissions and symlink targets are compared.",
            "A PASS self-comparison does not require release keys to exist. Changed keys must match the pinned release values; release configuration is independently required by verify-release.py."]}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("before_app", type=Path)
    parser.add_argument("after_app", type=Path)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    try:
        first, second = args.before_app.resolve(), args.after_app.resolve()
        require(first.is_dir() and second.is_dir(), "Both App inputs must be directories")
        require((first / "Contents/Info.plist").is_file() and (second / "Contents/Info.plist").is_file(), "Both App inputs require Contents/Info.plist")
        result = compare_apps(first, second)
    except (OSError, ValueError, struct.error, plistlib.InvalidFileException) as error:
        result = {"schemaVersion": 1, "status": "FAIL", "error": type(error).__name__ + ": " + str(error)}
    text = json.dumps(result, ensure_ascii=False, indent=2) + "\n"
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(text)
        print(json.dumps({"status": result["status"], "output": str(args.output), "comparedPaths": result.get("comparedPaths"), "machOFiles": result.get("machOFiles"), "failures": result.get("failures", result.get("error"))}, ensure_ascii=False))
    else:
        print(text, end="")
    return 0 if result["status"] == "PASS" else 1


if __name__ == "__main__":
    sys.exit(main())
