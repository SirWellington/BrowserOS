"""Keep the Windows wrapper aligned with the agent workspace, without building Chromium."""

import re
import subprocess
import sys
import tempfile
import tomllib
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[3]
SCRIPT = ROOT / "build.bat"


class BuildBatTest(unittest.TestCase):
    def setUp(self):
        self.script = SCRIPT.read_text(encoding="utf-8")
        self.command = next(
            line for line in self.script.splitlines() if line.startswith("cargo build ")
        )

    def test_source_package_and_binary_match_the_manifest(self):
        manifest = tomllib.loads(
            (ROOT / "packages/browseros-agent/apps/claw-server/Cargo.toml").read_text(
                encoding="utf-8"
            )
        )
        package = re.search(r" -p (\S+)", self.command).group(1)
        binary = re.search(r" --bin (\S+)", self.command).group(1)
        self.assertEqual(package, manifest["package"]["name"])
        self.assertIn(binary, {target["name"] for target in manifest["bin"]})
        self.assertIn("--locked", self.command)
        self.assertIn("--target x86_64-pc-windows-msvc", self.command)

    def test_version_lookup_uses_the_current_source_directory(self):
        relative = re.search(
            r"Select-String -Path '%AGENT_ROOT%\\([^']+)'", self.script
        ).group(1)
        manifest = ROOT / "packages/browseros-agent" / Path(relative.replace("\\", "/"))
        self.assertTrue(manifest.is_file(), relative)
        self.assertNotIn(r"apps\claw-server-rust\Cargo.toml", self.script)

    def test_source_binary_is_staged_with_unchanged_artifact_names(self):
        # The crate was renamed; the executable and release bundle were not.
        self.assertIn(r"release\browseros-claw-server-rs.exe", self.script)
        self.assertIn(r"dist\prod\claw-server-rust\browseros-claw-server-rust-resources-", self.script)
        self.assertIn(r"resources\binaries\browseros_claw_server_rust\windows-%ARCH%", self.script)

    def test_no_placeholder_analytics_key_is_injected(self):
        self.assertNotIn("CLAW_POSTHOG_KEY", self.script)

    def test_default_privacy_mode_builds_local_server_without_vendor_extensions(self):
        self.assertIn('if "%CORE_ONLY%"=="" set "CORE_ONLY=yes"', self.script)
        self.assertIn("--gn-arg browseros_core_only=true", self.script)
        self.assertIn("CORE_ONLY=yes requires AGENT_MODE=source", self.script)
        self.assertIn('set "DEPOT_TOOLS_METRICS=0"', self.script)
        self.assertIn('set "DEPOT_TOOLS_COLLECT_METRICS=0"', self.script)

    def test_reruns_preserve_build_outputs_and_support_verified_resume(self):
        self.assertIn('if "%CLEAN%"=="" set "CLEAN=no"', self.script)
        self.assertIn('set "CLEAN_FLAG=--no-clean"', self.script)
        self.assertIn('set "RESUME_FLAG=--from %RESUME_FROM%"', self.script)
        command = next(
            line for line in self.script.splitlines()
            if line.startswith("uv run browseros build ")
        )
        self.assertIn("%CLEAN_FLAG% %RESUME_FLAG%", command)

    @unittest.skipUnless(sys.platform == "win32", "Requires Windows cmd and PowerShell")
    def test_windows_version_command_reads_the_manifest_version(self):
        version_command = next(
            line for line in self.script.splitlines()
            if line.startswith("for /f %%v ")
        )
        agent = ROOT / "packages/browseros-agent"
        manifest = tomllib.loads((agent / "apps/claw-server/Cargo.toml").read_text())
        with tempfile.TemporaryDirectory() as directory:
            batch = Path(directory) / "version.bat"
            batch.write_text(
                '@echo off\nsetlocal\n'
                f'set "AGENT_ROOT={agent}"\n'
                'set "SERVER_VERSION="\n'
                f'{version_command}\n'
                'echo VERSION=%SERVER_VERSION%\n',
                encoding="utf-8", newline="\r\n",
            )
            result = subprocess.run(
                ["cmd.exe", "/d", "/c", str(batch)],
                capture_output=True, text=True, timeout=30,
            )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(f'VERSION={manifest["package"]["version"]}', result.stdout)


if __name__ == "__main__":
    unittest.main()
