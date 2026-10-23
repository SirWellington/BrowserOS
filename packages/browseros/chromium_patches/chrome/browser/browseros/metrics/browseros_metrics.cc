diff --git a/chrome/browser/browseros/metrics/browseros_metrics.cc b/chrome/browser/browseros/metrics/browseros_metrics.cc
new file mode 100644
--- /dev/null
+++ b/chrome/browser/browseros/metrics/browseros_metrics.cc
@@ -0,0 +1,14 @@
+// Copyright 2025 The Chromium Authors
+// Use of this source code is governed by a BSD-style license that can be
+// found in the LICENSE file.
+
+#include "chrome/browser/browseros/metrics/browseros_metrics.h"
+
+namespace browseros_metrics {
+
+// Keep callers source-compatible without collecting identifiers, queuing
+// events, writing telemetry to disk, or making network requests. Analytics
+// transport is deliberately absent from this build.
+void BrowserOSMetrics::Log(std::string_view, base::DictValue, double) {}
+
+}  // namespace browseros_metrics
