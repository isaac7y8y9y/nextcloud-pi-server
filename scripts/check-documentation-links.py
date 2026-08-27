#!/usr/bin/env python3
"""Validate relative links and Markdown heading fragments in tracked documentation."""

from __future__ import annotations

import html
import re
import subprocess
import sys
from pathlib import Path
from urllib.parse import unquote, urlsplit


ROOT = Path(__file__).resolve().parents[1]
LINK = re.compile(r"!?\[[^\]]*\]\(\s*(<[^>]+>|[^)\s]+)")
HEADING = re.compile(r"^ {0,3}#{1,6}\s+(.+?)\s*#*\s*$")
INLINE_LINK = re.compile(r"\[([^\]]+)\]\([^)]*\)")
INLINE_CODE = re.compile(r"`+([^`]*)`+")
HTML_TAG = re.compile(r"<[^>]+>")


def git_output(*args: str) -> str:
    return subprocess.check_output(
        ["git", "-C", str(ROOT), *args], stderr=subprocess.DEVNULL, text=True
    )


def markdown_files() -> list[Path]:
    relative_paths = git_output(
        "ls-files", "--cached", "--others", "--exclude-standard", "--", "*.md"
    ).splitlines()
    return [ROOT / relative_path for relative_path in relative_paths]


def extract_links(text: str) -> list[tuple[int, str]]:
    links: list[tuple[int, str]] = []
    fenced = False
    fence_marker = ""
    for line_number, line in enumerate(text.splitlines(), 1):
        stripped = line.lstrip()
        if stripped.startswith(("```", "~~~")):
            marker = stripped[:3]
            if not fenced:
                fenced = True
                fence_marker = marker
            elif marker == fence_marker:
                fenced = False
                fence_marker = ""
            continue
        if fenced:
            continue
        searchable = INLINE_CODE.sub("", line)
        for match in LINK.finditer(searchable):
            target = html.unescape(match.group(1).strip("<>"))
            links.append((line_number, target))
    return links


def heading_slug(heading: str) -> str:
    text = INLINE_LINK.sub(r"\1", heading)
    text = INLINE_CODE.sub(r"\1", text)
    text = HTML_TAG.sub("", text).strip().lower()
    text = re.sub(r"[^\w\- ]", "", text)
    return re.sub(r"\s+", "-", text)


def heading_anchors(path: Path) -> set[str]:
    anchors: set[str] = set()
    occurrences: dict[str, int] = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        match = HEADING.match(line)
        if not match:
            continue
        base = heading_slug(match.group(1))
        duplicate_number = occurrences.get(base, 0)
        occurrences[base] = duplicate_number + 1
        anchors.add(base if duplicate_number == 0 else f"{base}-{duplicate_number}")
    return anchors


def validate_file(source: Path, root: Path) -> list[str]:
    errors: list[str] = []
    root = root.resolve()
    source = source.resolve()
    for line_number, target in extract_links(source.read_text(encoding="utf-8")):
        parsed = urlsplit(target)
        if parsed.scheme or parsed.netloc:
            continue
        relative_path = unquote(parsed.path)
        destination = source if not relative_path else source.parent / relative_path
        destination = destination.resolve()
        try:
            destination.relative_to(root)
        except ValueError:
            errors.append(f"{source.relative_to(root)}:{line_number}: link leaves repository")
            continue
        if not destination.exists():
            errors.append(f"{source.relative_to(root)}:{line_number}: missing link target")
            continue
        if parsed.fragment and destination.is_file() and destination.suffix.lower() == ".md":
            fragment = unquote(parsed.fragment).lower()
            if fragment not in heading_anchors(destination):
                errors.append(f"{source.relative_to(root)}:{line_number}: missing heading fragment")
    return errors


def main() -> int:
    errors: list[str] = []
    for source in markdown_files():
        errors.extend(validate_file(source, ROOT))
    for error in errors:
        print(error)
    if errors:
        return 1
    print("documentation link validation passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
