#!/usr/bin/env python3
"""Regression tests for the Markdown link validator."""

from __future__ import annotations

import importlib.util
import sys
import tempfile
from pathlib import Path


sys.dont_write_bytecode = True
SCRIPT = Path(__file__).with_name("check-documentation-links.py")
SPEC = importlib.util.spec_from_file_location("documentation_links", SCRIPT)
assert SPEC and SPEC.loader
CHECKER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CHECKER)


def main() -> None:
    links = CHECKER.extract_links(
        "[guide](docs/guide.md#safe-example)\n"
        "`[ignored](missing.md)`\n"
        "```text\n[also ignored](missing.md)\n```\n"
    )
    assert links == [(1, "docs/guide.md#safe-example")]
    assert CHECKER.heading_slug("Safe `example`!") == "safe-example"

    with tempfile.TemporaryDirectory() as temporary_directory:
        root = Path(temporary_directory)
        docs = root / "docs"
        docs.mkdir()
        guide = docs / "guide.md"
        guide.write_text("# Safe example\n\n## Repeated\n## Repeated\n", encoding="utf-8")
        readme = root / "README.md"
        readme.write_text(
            "[guide](docs/guide.md#safe-example)\n"
            "[duplicate](docs/guide.md#repeated-1)\n"
            "[external](https://example.invalid/page)\n",
            encoding="utf-8",
        )
        assert CHECKER.validate_file(readme, root) == []

        readme.write_text("[missing](docs/missing.md)\n", encoding="utf-8")
        assert CHECKER.validate_file(readme, root) == ["README.md:1: missing link target"]

    print("documentation link validator tests passed")


if __name__ == "__main__":
    main()
