"""Regression tests for tools/patch_deps_updater.py.

The patcher drops the unused 32-bit/arm64 Windows Chromium updater CIPD entries
from DEPS (one of which, chrome_win_x86, is heuristically flagged by Windows
Defender and stalls gclient sync). These tests pin its selection, its edits, and
its idempotency/validity guarantees without touching a real checkout.
"""

import ast
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / "tools" / "patch_deps_updater.py"
PYTHON = [sys.executable]

# The four Windows updater entries a 64-bit build keeps, and the eight it drops.
KEEP = [
    "src/third_party/updater/chrome_win_x86_64/cipd",
    "src/third_party/updater/chrome_win_x86_64_sans_iid/cipd",
    "src/third_party/updater/chromium_win_x86_64/cipd",
    "src/third_party/updater/chromium_win_x86_64_sans_iid/cipd",
]
DROP = [
    "src/third_party/updater/chrome_win_x86/cipd",
    "src/third_party/updater/chrome_win_arm64/cipd",
    "src/third_party/updater/chrome_win_x86_sans_iid/cipd",
    "src/third_party/updater/chrome_win_arm64_sans_iid/cipd",
    "src/third_party/updater/chromium_win_x86/cipd",
    "src/third_party/updater/chromium_win_arm64/cipd",
    "src/third_party/updater/chromium_win_x86_sans_iid/cipd",
    "src/third_party/updater/chromium_win_arm64_sans_iid/cipd",
]
# Non-Windows entries must be left untouched (condition-gated, not fetched on Windows).
NON_WIN = [
    "src/third_party/updater/chrome_linux64/cipd",
    "src/third_party/updater/chromium_mac_arm64/cipd",
]


def make_deps() -> str:
    lines = ["vars = {"]
    for key in KEEP + DROP + NON_WIN:
        lines.append(f"  '{key}': {{")
        lines.append("      'dep_type': 'cipd',")
        lines.append("      'condition': 'checkout_win',")
        lines.append("      'packages': [")
        lines.append("        {")
        lines.append(f"          'package': 'x/{key}',")
        lines.append("          'version': 'v',")
        lines.append("        },")
        lines.append("      ],")
        lines.append("  },")
    lines.append("}")
    return "\n".join(lines) + "\n"


def run_patcher(deps_path: Path) -> subprocess.CompletedProcess:
    return subprocess.run(
        [*PYTHON, str(SCRIPT), "--deps", str(deps_path)],
        capture_output=True, text=True, timeout=60,
    )


class PatchDepsUpdaterTest(unittest.TestCase):
    def test_removes_only_unused_windows_arch_variants(self):
        with tempfile.TemporaryDirectory() as temp:
            deps = Path(temp) / "DEPS"
            deps.write_text(make_deps(), encoding="utf-8")
            result = run_patcher(deps)
            self.assertEqual(result.returncode, 0, result.stderr)
            text = deps.read_text(encoding="utf-8")
            for key in KEEP + NON_WIN:
                self.assertIn(f"'{key}': {{", text, f"should keep {key}")
            for key in DROP:
                self.assertNotIn(f"'{key}': {{", text, f"should drop {key}")
            # The result must still be valid Python.
            ast.parse(text)

    def test_is_idempotent(self):
        with tempfile.TemporaryDirectory() as temp:
            deps = Path(temp) / "DEPS"
            deps.write_text(make_deps(), encoding="utf-8")
            self.assertEqual(run_patcher(deps).returncode, 0)
            first = deps.read_text(encoding="utf-8")
            second = run_patcher(deps)
            self.assertEqual(second.returncode, 0, second.stderr)
            self.assertIn("already patched", second.stdout)
            self.assertEqual(deps.read_text(encoding="utf-8"), first)

    def test_build_wrapper_invokes_the_patcher(self):
        wrapper = Path(__file__).resolve().parents[2].parent / "build.bat"
        self.assertTrue(wrapper.is_file(), wrapper)
        script = wrapper.read_text(encoding="utf-8")
        self.assertIn("tools\\patch_deps_updater.py", script)
        self.assertIn("--deps \"%CHROMIUM_SRC%\\DEPS\"", script)


if __name__ == "__main__":
    unittest.main()
