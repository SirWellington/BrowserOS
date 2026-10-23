diff --git a/chrome/app/chrome_crash_reporter_client_win.cc b/chrome/app/chrome_crash_reporter_client_win.cc
--- a/chrome/app/chrome_crash_reporter_client_win.cc
+++ b/chrome/app/chrome_crash_reporter_client_win.cc
@@ -95,9 +95,8 @@ void ChromeCrashReporterClient::GetProductInfo(ProductInfo* product_info) {
   GetProductNameAndVersion(exe_file, &product_name, &version, &special_build,
                            &channel_name);
 
-  *product_info =
-      ProductInfo(base::WideToUTF8(product_name), base::WideToUTF8(version),
-                  base::WideToUTF8(channel_name));
+  *product_info = ProductInfo("BrowserOS", base::WideToUTF8(version),
+                             base::WideToUTF8(channel_name));
 }
 
 bool ChromeCrashReporterClient::GetShouldDumpLargerDumps() {
@@ -146,7 +145,8 @@ bool ChromeCrashReporterClient::IsRunningUnattended() {
 }
 
 bool ChromeCrashReporterClient::GetCollectStatsConsent() {
-  return install_static::GetCollectStatsConsent();
+  // Automatic crash uploads are disabled; no consent is assumed.
+  return false;
 }
 
 bool ChromeCrashReporterClient::GetCollectStatsInSample() {
@@ -236,3 +236,7 @@ std::wstring ChromeCrashReporterClient::GetWerRuntimeExceptionModule() {
   // file_start points to the start of the filename in the elf_dir buffer.
   return std::wstring(elf_dir, file_start).append(kWerDll);
 }
+
+std::string ChromeCrashReporterClient::GetUploadUrl() {
+  return std::string();
+}
