diff --git a/chrome/browser/browseros/metrics/browseros_metrics.h b/chrome/browser/browseros/metrics/browseros_metrics.h
new file mode 100644
index 0000000000000000000000000000000000000000..38f11187e8f9f49085c05135354dfbb242650d6d
--- /dev/null
+++ b/chrome/browser/browseros/metrics/browseros_metrics.h
@@ -0,0 +1,29 @@
+// Copyright 2025 The Chromium Authors
+// Use of this source code is governed by a BSD-style license that can be
+// found in the LICENSE file.
+
+#ifndef CHROME_BROWSER_BROWSEROS_METRICS_BROWSEROS_METRICS_H_
+#define CHROME_BROWSER_BROWSEROS_METRICS_BROWSEROS_METRICS_H_
+
+#include <string_view>
+
+#include "base/values.h"
+
+namespace browseros_metrics {
+
+// Compatibility entry point for former native analytics callers. This build
+// discards events and contains no analytics transport or tracking identity.
+class BrowserOSMetrics {
+ public:
+  // Safe from any thread. All arguments are ignored.
+  static void Log(std::string_view event_name,
+                  base::DictValue properties = {},
+                  double sample_rate = 1.0);
+
+ private:
+  BrowserOSMetrics() = delete;
+};
+
+}  // namespace browseros_metrics
+
+#endif  // CHROME_BROWSER_BROWSEROS_METRICS_BROWSEROS_METRICS_H_
