#!/usr/bin/env python3
"""Stage a published resource bundle from the public CDN into the build tree.

The download_resources step fetches these bundles via the R2 S3 API, which
needs credentials. The identical objects are also served anonymously at
cdn.browseros.com (the same bucket's public CDN), so local builds can stage
them without any secrets:

    python tools/stage_cdn_resources.py --zip <downloaded.zip> --dest <dir>

Extraction reuses extract_artifact_zip from the build system, which validates
every file against artifact-metadata.json (size + sha256) before keeping it.
"""

import argparse
from pathlib import Path

from bos_build.steps.storage.download import extract_artifact_zip


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Stage a published resource bundle zip into the build tree."
    )
    parser.add_argument("--zip", required=True, type=Path, help="Local path to the downloaded bundle zip")
    parser.add_argument("--dest", required=True, type=Path, help="Destination directory (relative to packages/browseros)")
    args = parser.parse_args()

    if not args.zip.is_file():
        raise SystemExit(f"Zip not found: {args.zip}")

    extract_artifact_zip(args.zip.resolve(), args.dest)
    print(f"[stage] Staged {args.zip.name} -> {args.dest}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
