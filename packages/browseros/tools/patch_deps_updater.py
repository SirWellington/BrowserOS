#!/usr/bin/env python3
"""Remove unused 32-bit/arm64 Windows Chromium updater CIPD entries from DEPS.

A 64-bit Windows build never uses the 32-bit or arm64 updater packages. One of
them (``chrome_win_x86``) is heuristically flagged by Windows Defender as
``Trojan:Win32/Suschil!rfn``, which stalls ``gclient sync`` before CIPD's own
SHA-256 verification can run. This script drops the unused Windows arch variants
from DEPS so the sync only fetches the 64-bit (``x86_64``) packages.

Safety properties:
- Idempotent: running it twice removes nothing the second time.
- Minimal: only touches ``*_win_*`` updater entries; linux/mac entries are
  condition-gated and left untouched.
- Validating: refuses to write if the patched file is no longer valid Python,
  and reports exactly which entries it removed.
"""

import argparse
import ast
import re
import sys
from pathlib import Path

KEY_RE = re.compile(
    r"^[ \t]*'(src/third_party/updater/[^']+/cipd)': \{", re.MULTILINE
)


def is_unwanted(key: str) -> bool:
    """True for Windows updater packages a 64-bit build never uses."""
    seg = key.split("/")[3]  # e.g. 'chrome_win_x86'
    if not (seg.startswith("chrome_win_") or seg.startswith("chromium_win_")):
        return False  # not a Windows updater package; leave it alone
    if "arm64" in seg:
        return True
    if seg.endswith("x86") or seg.endswith("x86_sans_iid"):
        return True
    return False  # x86_64 / x86_64_sans_iid are kept


def remove_entry(text: str, key: str) -> tuple[str, bool]:
    """Remove the DEPS dict entry whose key is ``key``.

    Locates the opening ``  '<key>': {`` line, then scans to the matching
    closing brace (tracking depth) and removes through the end of that line so
    the trailing ``},`` and newline are dropped cleanly.
    """
    open_line = f"  '{key}': {{"
    idx = text.find(open_line)
    if idx == -1:
        return text, False
    brace_idx = text.find("{", idx)
    depth = 0
    i = brace_idx
    while i < len(text):
        c = text[i]
        if c == "{":
            depth += 1
        elif c == "}":
            depth -= 1
            if depth == 0:
                eol = text.find("\n", i)
                end = eol + 1 if eol != -1 else len(text)
                return text[:idx] + text[end:], True
        i += 1
    raise ValueError(f"Unbalanced braces for DEPS entry {key}")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--deps", required=True, type=Path, help="Path to the DEPS file")
    args = ap.parse_args()

    raw = args.deps.read_bytes()
    text = raw.decode("utf-8")

    keys = KEY_RE.findall(text)
    unwanted = [k for k in keys if is_unwanted(k)]
    if not unwanted:
        print("[deps] No unused 32-bit/arm64 Windows updater entries to remove (already patched).")
        return 0

    for key in unwanted:
        text, removed = remove_entry(text, key)
        if not removed:
            print(f"[deps] ERROR: could not locate entry {key}", file=sys.stderr)
            return 1
        print(f"[deps] Removed {key}")

    # Refuse to write a corrupted DEPS: it must still parse as a Python module.
    try:
        ast.parse(text)
    except SyntaxError as exc:
        print(f"[deps] ERROR: patched DEPS is not valid Python: {exc}", file=sys.stderr)
        return 1

    args.deps.write_bytes(text.encode("utf-8"))
    print(f"[deps] Wrote {args.deps} ({len(unwanted)} entries removed).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
