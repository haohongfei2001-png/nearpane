#!/usr/bin/env python3
"""Validate delivered SVG/PNG/macOS icon assets without trusting the generator.

Usage:
    python verify_assets.py /absolute/delivery/directory --output report.json

Requires Python 3.10+ and Pillow. The report covers file integrity and claimed
dimensions; it is not a macOS runtime or design-quality certification.
"""

from __future__ import annotations

import argparse
import hashlib
import io
import json
import re
import struct
import sys
import xml.etree.ElementTree as ET
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from PIL import Image, IcnsImagePlugin, __version__ as PILLOW_VERSION


ICONSET_SIZES = (16, 32, 128, 256, 512)
ICNS_PIXEL_SIZES = {
    b"icp4": (16, 16), b"icp5": (32, 32), b"icp6": (64, 64),
    b"ic07": (128, 128), b"ic08": (256, 256), b"ic09": (512, 512),
    b"ic10": (1024, 1024), b"ic11": (32, 32), b"ic12": (64, 64),
    b"ic13": (256, 256), b"ic14": (512, 512),
}
LEGACY_ICNS_IMAGE_TAGS = {
    b"is32", b"s8mk", b"il32", b"l8mk", b"ih32", b"h8mk", b"it32", b"t8mk",
}
ICNS_METADATA_TAGS = {b"TOC ", b"icnV", b"name", b"info"}
SUPPORTED_PHYSICAL_SIZES = {16, 32, 64, 128, 256, 512, 1024}


def hash_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def local_name(tag: str) -> str:
    return tag.rsplit("}", 1)[-1]


def add_issue(record: dict[str, Any], severity: str, code: str, detail: str) -> None:
    record["issues"].append({"severity": severity, "code": code, "detail": detail})


def finish_record(record: dict[str, Any]) -> dict[str, Any]:
    severities = {item["severity"] for item in record["issues"]}
    record["status"] = "FAIL" if "error" in severities else "WARN" if "warning" in severities else "PASS"
    return record


def png_statistics(image: Image.Image) -> dict[str, Any]:
    image.load()
    rgba = image.convert("RGBA")
    alpha = rgba.getchannel("A")
    histogram = alpha.histogram()
    total = image.width * image.height
    extrema = rgba.getextrema()
    has_alpha = "A" in image.getbands() or "transparency" in image.info
    return {
        "dimensions_px": list(image.size),
        "mode": image.mode,
        "has_alpha_channel_or_transparency": has_alpha,
        "alpha_extrema": list(alpha.getextrema()),
        "transparent_pixels": histogram[0],
        "partially_transparent_pixels": sum(histogram[1:255]),
        "opaque_pixels": histogram[255],
        "visible_pixels": total - histogram[0],
        "visible_bbox": list(alpha.getbbox()) if alpha.getbbox() else None,
        "channel_extrema": [list(item) for item in extrema],
        "uniform_rgba": all(low == high for low, high in extrema),
    }


def expected_from_png_name(path: Path) -> tuple[int, int] | None:
    stem = path.stem
    match = re.fullmatch(r"icon_(\d+)x(\d+)(?:@(\d+)x)?", stem)
    if match:
        width, height, scale = match.groups()
        factor = int(scale or 1)
        return int(width) * factor, int(height) * factor
    # Only explicit width-by-height tokens are claims; do not infer from dates.
    match = re.search(r"(?:^|[-_])(\d{1,5})x(\d{1,5})(?:@(\d+)x)?(?:$|[-_])", stem)
    if match:
        width, height, scale = match.groups()
        factor = int(scale or 1)
        return int(width) * factor, int(height) * factor
    return None


def check_png(path: Path, record: dict[str, Any]) -> dict[str, Any]:
    with Image.open(path) as probe:
        if probe.format != "PNG":
            raise ValueError(f".png extension contains {probe.format!r}")
        probe.verify()
    with Image.open(path) as image:
        record.update(png_statistics(image))
        expected = expected_from_png_name(path)
        if expected is not None:
            record["expected_dimensions_from_filename_px"] = list(expected)
            if image.size != expected:
                add_issue(record, "error", "png_filename_dimension_mismatch", f"Filename claims {expected}; decoded {image.size}.")
        if not record["visible_pixels"]:
            add_issue(record, "error", "png_fully_transparent", "No visible pixel is present.")
        if record["uniform_rgba"]:
            add_issue(record, "warning", "png_uniform", "All pixels have the same RGBA value; inspect whether this is an intentional background layer.")
        if "transparent" in path.stem.lower() and record["transparent_pixels"] == 0:
            add_issue(record, "error", "transparency_claim_mismatch", "Filename claims transparent artwork but no fully transparent pixel is present.")
    return finish_record(record)


def check_svg(path: Path, record: dict[str, Any]) -> dict[str, Any]:
    content = path.read_text(encoding="utf-8-sig")
    if re.search(r"<!DOCTYPE|<!ENTITY", content, flags=re.I):
        add_issue(record, "error", "svg_external_entity_or_doctype", "DOCTYPE/entity declarations are disallowed for this self-contained asset delivery.")
    root = ET.fromstring(content)
    if local_name(root.tag) != "svg":
        raise ValueError("Root element is not SVG.")
    counts: dict[str, int] = {}
    external_references: list[str] = []
    raster_elements: list[str] = []
    for element in root.iter():
        name = local_name(element.tag)
        counts[name] = counts.get(name, 0) + 1
        if name.lower() in {"image", "feimage"}:
            raster_elements.append(name)
        if name in {"script", "foreignObject"}:
            add_issue(record, "error", "svg_active_or_foreign_content", f"Disallowed element: {name}.")
        for key, value in element.attrib.items():
            if local_name(key).lower() in {"href", "src"} and value.strip() and not value.strip().startswith("#"):
                external_references.append(value)
    if raster_elements:
        add_issue(record, "error", "svg_raster_image_element", f"Found raster-capable image elements: {raster_elements}.")
    if re.search(r"base64\s*,|data\s*:", content, flags=re.I):
        add_issue(record, "error", "svg_embedded_data", "Embedded data/base64 found; vector source must consist of real vector artwork.")
    for match in re.finditer(r"url\(\s*['\"]?([^)'\"]+)", content, flags=re.I):
        if not match.group(1).strip().startswith("#"):
            external_references.append(match.group(1))
    if re.search(r"@import\b", content, flags=re.I):
        add_issue(record, "error", "svg_css_import", "CSS @import makes the asset externally dependent.")
    if external_references:
        add_issue(record, "error", "svg_external_references", f"Nonlocal references: {external_references}.")
    drawable = sum(counts.get(tag, 0) for tag in ("path", "rect", "circle", "ellipse", "polygon", "polyline", "line", "text", "use"))
    if drawable == 0:
        add_issue(record, "error", "svg_no_drawable_elements", "No vector drawing element found.")
    if counts.get("text", 0):
        add_issue(record, "warning", "svg_live_text", "Live text remains; fonts may affect the artwork on another machine.")
    view_box = root.get("viewBox")
    if view_box:
        values = [float(number) for number in re.split(r"[\s,]+", view_box.strip())]
        if len(values) != 4 or values[2] <= 0 or values[3] <= 0:
            add_issue(record, "error", "svg_invalid_viewbox", f"Invalid viewBox: {view_box!r}.")
        record["viewBox"] = values
    else:
        add_issue(record, "warning", "svg_missing_viewbox", "No viewBox; scale behavior depends on width/height attributes.")
    record["element_counts"] = counts
    record["real_vector_elements"] = drawable
    record["embedded_raster_count"] = len(raster_elements)
    return finish_record(record)


def check_icns(path: Path, record: dict[str, Any]) -> dict[str, Any]:
    data = path.read_bytes()
    if len(data) < 8:
        raise ValueError("ICNS header is truncated.")
    signature, declared_size = struct.unpack(">4sI", data[:8])
    if signature != b"icns":
        raise ValueError(f"Invalid ICNS signature {signature!r}.")
    if declared_size != len(data):
        raise ValueError(f"ICNS header length {declared_size} does not match file length {len(data)}.")
    offset, seen, chunks = 8, set(), []
    decoded_pixel_sizes: set[int] = set()
    while offset < len(data):
        if offset + 8 > len(data):
            raise ValueError("Trailing truncated ICNS chunk header.")
        tag, length = struct.unpack(">4sI", data[offset:offset + 8])
        if length < 8 or offset + length > len(data):
            raise ValueError(f"Invalid chunk length {length} at offset {offset}.")
        tag_name = tag.decode("ascii", errors="backslashreplace")
        chunk: dict[str, Any] = {"type": tag_name, "offset": offset, "length": length}
        if tag in seen:
            add_issue(record, "error", "icns_duplicate_chunk", f"Duplicate chunk type {tag_name}; readers may select different copies.")
        seen.add(tag)
        payload = data[offset + 8:offset + length]
        if tag in ICNS_PIXEL_SIZES:
            with Image.open(io.BytesIO(payload)) as frame:
                frame.load()
                expected = ICNS_PIXEL_SIZES[tag]
                if frame.size != expected:
                    add_issue(record, "error", "icns_chunk_dimension_mismatch", f"{tag_name}: expected {expected}, decoded {frame.size}.")
                chunk.update(png_statistics(frame))
                chunk["payload_format"] = frame.format
                chunk["expected_dimensions_px"] = list(expected)
                if chunk["visible_pixels"] == 0:
                    add_issue(record, "error", "icns_empty_frame", f"{tag_name} is fully transparent.")
                decoded_pixel_sizes.add(frame.width)
        elif tag in LEGACY_ICNS_IMAGE_TAGS:
            chunk["decoding"] = "decoded below using Pillow ICNS channels"
        elif tag in ICNS_METADATA_TAGS:
            chunk["decoding"] = "metadata, not an image payload"
        else:
            add_issue(record, "error", "icns_unverified_chunk", f"Unrecognized chunk {tag_name}; no verified raster decoder assigned.")
        chunks.append(chunk)
        offset += length
    if not chunks:
        add_issue(record, "error", "icns_no_chunks", "Container holds no resources.")
    # Decode all representations through Pillow's independent ICNS reader too.
    with path.open("rb") as handle:
        container = IcnsImagePlugin.IcnsFile(handle)
        representations = []
        for points_width, points_height, scale in container.itersizes():
            frame = container.getimage((points_width, points_height, scale))
            frame.load()
            expected = (points_width * scale, points_height * scale)
            if frame.size != expected:
                add_issue(record, "error", "icns_representation_dimension_mismatch", f"{(points_width, points_height, scale)} decoded to {frame.size}, expected {expected}.")
            representations.append({"points": [points_width, points_height], "scale": scale, **png_statistics(frame)})
            decoded_pixel_sizes.add(frame.width)
        if not representations:
            add_issue(record, "error", "icns_no_decodable_representations", "Pillow found no image representation.")
    missing = sorted(SUPPORTED_PHYSICAL_SIZES - decoded_pixel_sizes)
    if missing:
        add_issue(record, "error", "icns_incomplete_size_coverage", f"Missing physical sizes required by this delivery: {missing}.")
    record.update({"declared_file_length": declared_size, "chunks": chunks, "representations": representations, "decoded_pixel_sizes": sorted(decoded_pixel_sizes)})
    return finish_record(record)


def check_contents(path: Path, record: dict[str, Any], delivery_root: Path) -> dict[str, Any]:
    content = json.loads(path.read_text(encoding="utf-8"))
    entries = content.get("images")
    if not isinstance(entries, list):
        raise ValueError("AppIcon Contents.json must contain an images array.")
    checked_entries, slots = [], set()
    for index, entry in enumerate(entries):
        item = {"index": index, **entry}
        filename = entry.get("filename")
        if not filename:
            add_issue(record, "error", "appicon_missing_filename", f"Image entry {index} has no filename.")
            checked_entries.append(item)
            continue
        image_path = (path.parent / filename).resolve()
        if not image_path.is_relative_to(delivery_root.resolve()):
            add_issue(record, "error", "appicon_path_escape", f"Entry {index} points outside the delivered folder.")
            checked_entries.append(item)
            continue
        if not image_path.is_file():
            add_issue(record, "error", "appicon_missing_file", f"Entry {index} file does not exist: {filename}.")
            checked_entries.append(item)
            continue
        size_match = re.fullmatch(r"(\d+(?:\.\d+)?)x(\d+(?:\.\d+)?)", entry.get("size", ""))
        scale_match = re.fullmatch(r"(\d+(?:\.\d+)?)x", entry.get("scale", ""))
        if not size_match or not scale_match:
            add_issue(record, "error", "appicon_invalid_size_or_scale", f"Entry {index} lacks a valid point size/scale.")
            checked_entries.append(item)
            continue
        scale = float(scale_match.group(1))
        expected_float = [float(value) * scale for value in size_match.groups()]
        if any(value != int(value) or value <= 0 for value in expected_float):
            add_issue(record, "error", "appicon_noninteger_pixel_dimensions", f"Entry {index} implies {expected_float} pixels.")
            checked_entries.append(item)
            continue
        expected = tuple(int(value) for value in expected_float)
        with Image.open(image_path) as image:
            image.load()
            item["expected_dimensions_px"] = list(expected)
            item["decoded_dimensions_px"] = list(image.size)
            if image.size != expected:
                add_issue(record, "error", "appicon_dimension_mismatch", f"{filename}: JSON says {expected}, image is {image.size}.")
        slot = (entry.get("idiom"), entry.get("size"), entry.get("scale"), json.dumps(entry.get("appearances", []), sort_keys=True))
        if slot in slots:
            add_issue(record, "error", "appicon_duplicate_slot", f"Duplicate asset slot: {slot}.")
        slots.add(slot)
        checked_entries.append(item)
    required_slots = {(f"{size}x{size}", f"{scale}x") for size in ICONSET_SIZES for scale in (1, 2)}
    provided_slots = {(entry.get("size"), entry.get("scale")) for entry in entries if entry.get("idiom") == "mac"}
    missing = sorted(required_slots - provided_slots)
    if missing:
        add_issue(record, "error", "appicon_incomplete_mac_slots", f"Missing classic macOS slots: {missing}.")
    record["entries"] = checked_entries
    return finish_record(record)


def check_iconset(path: Path, delivery_root: Path) -> dict[str, Any]:
    record: dict[str, Any] = {"path": str(path.relative_to(delivery_root)), "kind": "iconset", "issues": []}
    checked = []
    for size in ICONSET_SIZES:
        for scale in (1, 2):
            filename = f"icon_{size}x{size}{'@2x' if scale == 2 else ''}.png"
            file = path / filename
            if not file.is_file():
                add_issue(record, "error", "iconset_missing_slot", f"Missing {filename}.")
                continue
            with Image.open(file) as image:
                image.load()
                expected = (size * scale, size * scale)
                if image.size != expected:
                    add_issue(record, "error", "iconset_dimension_mismatch", f"{filename}: {image.size} instead of {expected}.")
                checked.append({"filename": filename, "points": size, "scale": scale, "dimensions_px": list(image.size)})
    record["slots"] = checked
    return finish_record(record)


def validate(delivery_root: Path) -> dict[str, Any]:
    files = sorted(path for path in delivery_root.rglob("*") if path.is_file())
    records = []
    for path in files:
        extension = path.suffix.lower()
        is_contents = path.name == "Contents.json" and path.parent.name.endswith(".appiconset")
        if extension not in {".png", ".svg", ".icns"} and not is_contents:
            continue
        record = {"path": str(path.relative_to(delivery_root)), "kind": "appicon_contents" if is_contents else extension[1:], "bytes": path.stat().st_size, "sha256": hash_file(path), "issues": []}
        try:
            if extension == ".png":
                check_png(path, record)
            elif extension == ".svg":
                check_svg(path, record)
            elif extension == ".icns":
                check_icns(path, record)
            else:
                check_contents(path, record, delivery_root)
        except Exception as exc:
            add_issue(record, "error", "decode_or_validation_exception", f"{type(exc).__name__}: {exc}")
            finish_record(record)
        records.append(record)
    for path in sorted(delivery_root.rglob("*.iconset")):
        if path.is_dir():
            try:
                records.append(check_iconset(path, delivery_root))
            except Exception as exc:
                record = {"path": str(path.relative_to(delivery_root)), "kind": "iconset", "issues": []}
                add_issue(record, "error", "iconset_validation_exception", f"{type(exc).__name__}: {exc}")
                records.append(finish_record(record))
    counts = {kind: sum(record["kind"] == kind for record in records) for kind in ("png", "svg", "icns", "appicon_contents", "iconset")}
    failed = sum(record["status"] == "FAIL" for record in records)
    warnings = sum(record["status"] == "WARN" for record in records)
    global_issues = []
    for kind, count in counts.items():
        if count == 0:
            global_issues.append({"severity": "error", "code": "missing_asset_kind", "detail": f"No {kind} asset found."})
    return {
        "schema_version": "1.0",
        "generated_at_utc": datetime.now(timezone.utc).isoformat(),
        "delivery_root": str(delivery_root.resolve()),
        "validator": {"python": sys.version.split()[0], "pillow": PILLOW_VERSION, "script": Path(__file__).name},
        "scope": "Independent file-format, dimension, alpha, embedded-raster, ICNS-decoding and asset-catalog integrity checks.",
        "not_verified": ["macOS Finder/Dock runtime behavior", "Xcode compilation", "Icon Composer .icon rendering", "visual design quality or trademark clearance"],
        "overall_status": "FAIL" if failed or global_issues else "WARN" if warnings else "PASS",
        "summary": {"records": len(records), "failed_records": failed, "warning_records": warnings, "asset_kind_counts": counts},
        "global_issues": global_issues,
        "records": records,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", type=Path, help="Root of the delivered icon package")
    parser.add_argument("--output", type=Path, help="Write complete JSON to this path; otherwise print JSON to stdout")
    args = parser.parse_args()
    root = args.directory.resolve()
    if not root.is_dir():
        parser.error(f"Delivery directory does not exist: {root}")
    report = validate(root)
    rendered = json.dumps(report, ensure_ascii=False, indent=2)
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(rendered + "\n", encoding="utf-8")
        print(json.dumps({"overall_status": report["overall_status"], **report["summary"], "report": str(args.output.resolve())}, ensure_ascii=False))
    else:
        print(rendered)
    return 1 if report["overall_status"] == "FAIL" else 0


if __name__ == "__main__":
    raise SystemExit(main())
