# Automatic telemetry is disabled

This checkout hard-disables automatic usage analytics and remote error reporting in the agent apps and servers. Build keys, runtime environment variables, and previously saved telemetry consent cannot enable them.

- The BrowserOS extension has an inert PostHog compatibility client, with no SDK loading, session recorder, identity persistence, or event buffering.
- The extension's `track()` and browser adapter metric methods no longer gather version metadata or forward UI events to native browser analytics.
- The Bun server metrics sink does not create a PostHog client, retain installation metadata, aggregate usage, or schedule flushes.
- Neither the extension nor the Bun server initializes Sentry, so existing capture calls have no transport and automatic error/breadcrumb integrations are not installed.
- The extension build no longer installs the Sentry Vite plugin, including its own telemetry and automatic source-map uploads.
- The Rust BrowserClaw server never activates its analytics client or alias worker, regardless of consent or credentials, and exposes no PostHog remote-configuration credentials.
- The BrowserClaw cockpit does not load PostHog or its recorder, even if a server reports telemetry enabled.
- The Rust run-failure reporter has no automatic sink and does not build remote reports or write the separate diagnostic payload log.
- After the upstream error-reporting refactor, the replacement runtime error reporter remains disabled, and the new startup/panic reporter is an inert compatibility API with no client, identity, or reporting budget files.

Explicit feedback, bug reports, waitlist submissions, local operational logs, and functional AI/API traffic are unchanged. The Rust telemetry settings API still persists a consent preference and local identity for wire compatibility, but effective delivery stays disabled. Analytics-based cockpit flags remain off without remote evaluation. An explicitly configured feedback-cohort document can still be fetched; the implicit PostHog configuration fallback is disabled.

Dormant SDK dependencies and sanitizer/test utilities remain, but production initialization paths cannot activate automatic delivery. Native browser telemetry is outside this directory and is handled separately. Existing published binaries and generated extension bundles must be rebuilt; changing these sources does not modify an already-installed build.
