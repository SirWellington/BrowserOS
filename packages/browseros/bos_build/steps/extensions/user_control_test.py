"""Source-contract checks for Chromium patches; these do not run Chromium."""

import subprocess
import unittest
from pathlib import Path


PATCHES = Path(__file__).resolve().parents[3] / "chromium_patches"


def added_source(relative: str) -> str:
    text = (PATCHES / relative).read_text(encoding="utf-8")
    return "\n".join(
        line[1:] for line in text.splitlines()
        if line.startswith("+") and not line.startswith("+++")
    )


class UserControlTest(unittest.TestCase):
    def test_core_only_disables_vendor_recovery_and_replacement(self):
        flags = added_source("chrome/browser/browseros/buildflags.gni")
        self.assertIn("browseros_core_only = false", flags)
        self.assertIn("if (browseros_core_only)", flags)
        self.assertIn("browseros_package_all_server_resources = false", flags)
        self.assertIn("browseros_allow_runtime_product_override = false", flags)
        for relative in (
            "chrome/browser/extensions/external_provider_impl.cc",
            "chrome/browser/browseros/core/browseros_constants.h",
            "chrome/browser/browseros/onboarding/browseros_onboarding_prefs.cc",
            "chrome/browser/browseros/server/browseros_server_manager.cc",
            "chrome/browser/browseros/server/server_state_store_impl.cc",
            "chrome/browser/win/winsparkle_glue.cc",
        ):
            self.assertIn("IsBrowserOSCoreOnly()", added_source(relative), relative)
        bundles = added_source("chrome/browser/browseros/bundled_extensions/BUILD.gn")
        self.assertIn('if (browseros_core_only)', bundles)
        self.assertIn('group("bundled_extensions")', bundles)

    def test_bundles_are_not_components_or_policy_installs(self):
        source = added_source("chrome/browser/extensions/external_provider_impl.cc")
        self.assertIn("ManifestLocation::kExternalPref,", source)
        self.assertIn("ManifestLocation::kExternalPrefDownload,", source)
        self.assertNotIn("ManifestLocation::kExternalComponent", source)
        self.assertNotIn("ManifestLocation::kExternalPolicy", source)

    def test_existing_component_installs_are_migrated_before_loading(self):
        source = added_source("chrome/browser/extensions/installed_loader.cc")
        self.assertIn("IsKnownBrowserOSExtension(info.extension_id)", source)
        self.assertIn("mojom::ManifestLocation::kExternalComponent", source)
        self.assertIn("SetInstallLocation(info.extension_id,", source)
        self.assertIn("AcknowledgeExternalExtension(info.extension_id)", source)
        self.assertNotIn("kExternalPolicy", source)

    def test_no_product_force_pins_or_disable_removal_overrides(self):
        for relative in (
            "chrome/browser/ui/toolbar/toolbar_actions_model.cc",
            "chrome/browser/extensions/extension_context_menu_model.cc",
            "chrome/browser/extensions/chrome_extension_registrar_delegate.cc",
            "chrome/browser/ui/views/side_panel/extensions/extension_side_panel_action_item_util.cc",
        ):
            self.assertFalse((PATCHES / relative).exists(), relative)
        self.assertNotIn("GetForcePinnedList", added_source(
            "chrome/browser/extensions/extension_management.cc"))

    def test_readiness_and_maintenance_do_not_reenable_extensions(self):
        directory = PATCHES / "chrome/browser/browseros/extensions"
        for path in directory.glob("*.cc"):
            source = added_source(str(path.relative_to(PATCHES)))
            self.assertNotIn("EnableExtension(", source, path.name)
            self.assertNotIn("ClearExternalExtensionUninstalled(", source, path.name)
        loader = added_source("chrome/browser/browseros/extensions/browseros_extension_loader.cc")
        # EnsureReady, BeginReadiness and AdvanceReadiness all honor opt-outs.
        self.assertEqual(loader.count("IsExtensionDisabled(primary_id_)"), 3)
        desired = loader.split("BrowserOSExtensionLoader::BuildDesiredPrefs()", 1)[1]
        desired = desired.split("BrowserOSExtensionLoader::BeginReadiness()", 1)[0]
        self.assertLess(desired.index("IsExternalExtensionUninstalled(id)"),
                        desired.index("NeedsLocalInstall(id)"))

    def test_native_analytics_has_no_transport_or_identity_service(self):
        directory = PATCHES / "chrome/browser/browseros/metrics"
        self.assertEqual({path.name for path in directory.iterdir()}, {
            "BUILD.gn", "browseros_metrics.cc", "browseros_metrics.h",
        })
        source = added_source("chrome/browser/browseros/metrics/browseros_metrics.cc")
        for forbidden in ("PostTask", "CaptureEvent", "SimpleURLLoader", "install_id", "https://"):
            self.assertNotIn(forbidden, source)
        self.assertNotIn("services/network", added_source("chrome/browser/browseros/metrics/BUILD.gn"))
        self.assertNotIn("AddBrowserOSMetricsExtraParts", added_source("chrome/browser/chrome_browser_main.cc"))

    def test_crash_uploads_have_neither_consent_nor_destination(self):
        for name in ("chrome_crash_reporter_client.cc", "chrome_crash_reporter_client_win.cc"):
            source = added_source("chrome/app/" + name)
            self.assertIn("return false;", source)
            self.assertIn("return std::string();", source)
            self.assertNotIn("return true;", source)
            self.assertNotIn("sentry", source.lower())

    def test_affected_patches_have_valid_hunk_counts(self):
        # All files touched by this privacy/user-control change are checked by
        # git's patch parser, even without a local Chromium checkout.
        for directory in (
            "chrome/browser/browseros/extensions",
            "chrome/browser/browseros/metrics",
            "chrome/browser/browseros/core",
            "chrome/app",
            "chrome/browser/extensions",
        ):
            for path in (PATCHES / directory).glob("*"):
                if not path.is_file():
                    continue
                result = subprocess.run(
                    ["git", "apply", "--numstat", str(path)],
                    capture_output=True, text=True,
                )
                self.assertEqual(result.returncode, 0, f"{path.name}: {result.stderr}")


if __name__ == "__main__":
    unittest.main()
