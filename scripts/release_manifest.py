#!/usr/bin/env python3
"""Create a deterministic release manifest for already-built artifacts."""

from __future__ import annotations

import argparse
import hashlib
import json
import subprocess
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--version", required=True)
    arguments = parser.parse_args()

    artifacts = {
        "codex-capslock-indicator": ROOT
        / ".build/release/codex-capslock-indicator",
        "codex-capslock-magsafe-helper": ROOT
        / ".build/release/codex-capslock-magsafe-helper",
    }
    missing = [str(path) for path in artifacts.values() if not path.is_file()]
    if missing:
        raise SystemExit(f"Missing release artifacts: {', '.join(missing)}")

    commit = subprocess.run(
        ["git", "rev-parse", "HEAD"],
        cwd=ROOT,
        check=True,
        text=True,
        stdout=subprocess.PIPE,
    ).stdout.strip()
    manifest = {
        "version": arguments.version,
        "commit": commit,
        "protocolVersion": 2,
        "minimumMacOS": "14.0",
        "minimumSwift": "6.2",
        "minimumPython": "3.10",
        "artifacts": {
            name: {"sha256": sha256(path)}
            for name, path in sorted(artifacts.items())
        },
    }
    arguments.output.parent.mkdir(parents=True, exist_ok=True)
    arguments.output.write_text(
        json.dumps(manifest, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
