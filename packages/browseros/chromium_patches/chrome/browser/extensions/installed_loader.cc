diff --git a/chrome/browser/extensions/installed_loader.cc b/chrome/browser/extensions/installed_loader.cc
--- a/chrome/browser/extensions/installed_loader.cc
+++ b/chrome/browser/extensions/installed_loader.cc
@@ -26,5 +26,6 @@
 #include "build/chromeos_buildflags.h"
 #include "chrome/browser/browser_process.h"
+#include "chrome/browser/browseros/core/browseros_constants.h"
 #include "chrome/browser/extensions/corrupted_extension_reinstaller.h"
 #include "chrome/browser/extensions/extension_allowlist_factory.h"
 #include "chrome/browser/extensions/extension_management.h"
@@ -364,4 +365,16 @@ void InstalledLoader::LoadAllExtensions(Profile* profile) {
   for (auto& info : extensions_info) {
+    // Older BrowserOS builds installed bundled extensions as components. Drop
+    // only that product-owned privilege before creating the Extension object;
+    // policy-installed, unpacked and unrelated extensions are left untouched.
+    if (browseros::IsKnownBrowserOSExtension(info.extension_id) &&
+        info.extension_location ==
+            mojom::ManifestLocation::kExternalComponent) {
+      info.extension_location = mojom::ManifestLocation::kExternalPrefDownload;
+      extension_prefs_->SetInstallLocation(info.extension_id,
+                                          info.extension_location);
+      extension_prefs_->AcknowledgeExternalExtension(info.extension_id);
+    }
+
     // Skip extensions that were loaded from the command-line because we don't
     // want those to persist across browser restart.
     if (info.extension_location == mojom::ManifestLocation::kCommandLine) {
