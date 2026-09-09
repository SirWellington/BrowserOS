#!/usr/bin/env python3
"""Stage a locally built claw-server-rust binary into the build tree.

Mirrors ServerResourceBuilder._stage_rust from bos_build for hosts where the
official source-mode pipeline is not available (e.g. Windows without CRX
signing keys): copy the cargo output and skill file, then write the same
artifact-metadata.json the published bundles carry so downstream validation
treats them identically:

    python tools/stage_local_server.py \
        --exe <target/.../browseros-claw-server-rs.exe> \
        --skill <packages/browseros-agent/resources/skills/browserclaw/SKILL.md> \
        --dest resources/binaries/browseros_claw_server_rust/windows-x64 \
        --version 0.0.52 --source-sha <git HEAD> [--zip-out <bundle.zip>]

--zip-out writes the canonical published-style bundle (artifact-metadata.json
plus resources/ at the zip root) for artifact parity with cdn.browseros.com.
"""

import argparse
import hashlib
import json
import re
import shutil
import zipfile
from pathlib import Path


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as stream:
        while chunk := stream.read(1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Stage a locally built claw-server-rust binary into the build tree."
    )
    parser.add_argument("--exe", required=True, type=Path, help="cargo output browseros-claw-server-rs(.exe)")
    parser.add_argument("--skill", required=True, type=Path, help="browserclaw SKILL.md source file")
    parser.add_argument("--dest", required=True, type=Path, help="Destination directory (relative to packages/browseros)")
    parser.add_argument("--version", required=True, help="Component version from apps/claw-server-rust/Cargo.toml")
    parser.add_argument("--target", default="windows-x64", help="Server target id (default: windows-x64)")
    parser.add_argument("--source-sha", required=True, help="Full 40-char git HEAD of the checkout being built")
    parser.add_argument("--zip-out", type=Path, default=None, help="Optional canonical bundle zip to write")
    args = parser.parse_args()

    if not re.fullmatch(r"[0-9a-fA-F]{40}", args.source_sha):
        raise SystemExit(f"source-sha must be a full 40-char git SHA: {args.source_sha}")
    for name in ("exe", "skill"):
        path = getattr(args, name)
        if not path.is_file():
            raise SystemExit(f"{name} not found: {path}")

    dest = args.dest
    if dest.exists():
        shutil.rmtree(dest)
    suffix = ".exe" if args.target.startswith("windows") else ""
    runtime = dest / "resources" / "bin" / f"browseros-claw-server{suffix}"
    skill = dest / "resources" / "skills" / "browserclaw" / "SKILL.md"
    runtime.parent.mkdir(parents=True)
    shutil.copy2(args.exe, runtime)
    skill.parent.mkdir(parents=True)
    shutil.copy2(args.skill, skill)

    files = [runtime, skill]
    document = {
        "version": args.version,
        "target": args.target,
        "sourceSha": args.source_sha,
        "files": [
            {
                "path": path.relative_to(dest).as_posix(),
                "size": path.stat().st_size,
                "sha256": _sha256(path),
            }
            for path in files
        ],
    }
    (dest / "artifact-metadata.json").write_text(
        json.dumps(document, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )

    if args.zip_out:
        args.zip_out.parent.mkdir(parents=True, exist_ok=True)
        with zipfile.ZipFile(args.zip_out, "w", zipfile.ZIP_DEFLATED) as archive:
            archive.write(dest / "artifact-metadata.json", "artifact-metadata.json")
            for path in sorted(dest.rglob("*")):
                if path.is_file() and path.name != "artifact-metadata.json":
                    archive.write(path, path.relative_to(dest).as_posix())

    print(f"[stage] Staged local server {args.version} ({args.target}) -> {dest}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
