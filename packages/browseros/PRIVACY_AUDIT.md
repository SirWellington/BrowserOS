# Privacy and user-control audit

This is a source-code audit dated 2026-10-22, not a capture of traffic from an
installed browser. The findings below describe the code before the accompanying
changes. They cannot establish what any particular installation already sent,
the recipient's retention policy, or who accessed the recipient's storage.

The subsequent upstream merge renamed Rust's `services/run_failures.rs` to
`services/error_reporting/mod.rs` and introduced a startup/panic reporter. The
disabled runtime sink was preserved through that refactor; the new startup
reporter was also made inert so the merge cannot restore automatic reporting.

## Native browser analytics

The former `chromium_patches/chrome/browser/browseros/metrics/` implementation
started a process-wide analytics service before profiles were initialized.
There was no consent or settings gate. The network annotation explicitly stated
that it could not be disabled in settings.

The service sent HTTP POST requests to `https://us.i.posthog.com/i/v0/e/`, using
different product projects for BrowserOS and BrowserClaw. Events contained:

- A persistent installation UUID as both `distinct_id` and `install_id`.
- The product name, native surface, browser version, OS name/version, and CPU architecture.
- An event name and caller-provided property dictionary.
- A sampling-rate property for sampled events.

Examples of native events included the following.

- A sampled `alive` event was triggered when the browser was active.
- Side-panel events recorded panel creation, provider changes, screenshot capture, and content-copy actions.
- Extension-health events included extension ID, state, maintenance context, and disable-reason bitmask.
- Server-update events included versions, failure reasons, update stages, and health/rollback outcomes.
- Browser settings and the extension-facing `browserOS` API could supply additional event properties.

The screenshot-capture and copy-action events inspected here did not themselves
attach screenshots or clipboard contents. However, the native sender accepted
arbitrary caller properties without a central redaction pass. Calling this
"anonymous" did not make it unlinkable: the same UUID joined events over time
and was shared with sidecars. A remote HTTPS recipient also necessarily sees
the connecting IP address; source code does not prove how it stores that address.

### Native local storage

The UUID was saved as `install_id` in `installation.json`, under
`%USERPROFILE%\.browseros` or `%USERPROFILE%\.browserclaw` by default on Windows.
`BROWSEROS_DIR` and `BROWSERCLAW_DIR` could override these roots. The native
startup-event queue was held in memory, not a persistent on-disk analytics queue.
Failed uploads could write status codes and server response bodies to browser logs.

### Native crash reports

Both `chrome/app/chrome_crash_reporter_client.cc` and its Windows counterpart
overrode `GetCollectStatsConsent()` to return `true`. They selected a Sentry
US-ingestion minidump endpoint, independent of PostHog usage analytics. Crash
minidumps are a separate, potentially sensitive diagnostic channel; the exact
contents of a real dump were not examined in this audit.

### Changes in this branch

- The native PostHog sender, process-startup registration, and installation-ID generator have been removed.
- The old metrics API now discards events, so remaining callers cannot queue or upload them.
- Native automatic crash consent now returns `false`, and the upload URL is empty on both platform implementations.
- Existing local identity files and logs have not been deleted, and previously uploaded data has not been recalled.

These changes require rebuilding and installing the browser. Editing this
repository does not change a browser binary that is already running.

Packaging must also use freshly built agent and extension artifacts from this
checkout. The build system supports downloading published vendor bundles; those
do not contain local source changes. Likewise, future upstream browser, sidecar,
or extension updates can replace a privacy-modified build. The default Windows
wrapper intends to source-build the BrowserClaw server, but currently references
the former `claw-server-rust` Cargo package/path instead of `claw-server`, and does
not establish that all bundled CRXs were rebuilt. No privacy-clean distributable
has been produced or verified by this source-only change.

## Agent/MCP analytics and error reporting

The browser-control servers had independent telemetry hooks. Disabling the
native browser sender alone would not have stopped these. Their delivery sinks
are now disabled in `../browseros-agent`; see
[the agent change summary](../browseros-agent/AUTOMATIC-TELEMETRY.md).

### Older BrowserOS Bun server

The original `apps/server/src/lib/metrics.ts` sent to PostHog's US Cloud endpoint
when a project key and installation ID were available. It had no user-consent
check. Thirty-minute usage rollups contained MCP request counts, tool execution
and failure totals, and counts by tool name/source. Immediate sampled events
included chat provider/model and server startup. Common properties included the
installation UUID and product/browser/server versions.

The tool observer supplied duration and error text, but the original rollup
discarded those fields. It did not attach tool arguments, results, page text,
screenshots, or typed input to that PostHog payload.

The independent `apps/server/src/lib/sentry.ts` initialized Sentry from its
configured DSN with `sendDefaultPii: true` and installation-based correlation.
Its key-based credential sanitizer did not comprehensively scrub arbitrary
exception messages, URLs, or all top-level Sentry fields. Thus the narrow
PostHog rollup does not establish a similarly narrow error-reporting payload.

### Rust BrowserClaw MCP server

The original `apps/claw-server/src/analytics/service.rs` used PostHog US Cloud by
default, with a configurable host. Delivery required credentials and effective
consent, but `analytics/state.rs` defaulted the persisted preference to `true`.
This was opt-out behavior, not affirmative opt-in before the first capture.

The allowlisted event schemas in `analytics/events.rs` included:

- Server startup and agent-session start/end events.
- Agent client and connected harness names.
- Task category and an optional free-text task summary, capped at 200 characters.
- Known tool names, dispatch counts, aggregate/max durations, and concurrency counts.
- Numeric token-use/savings estimates and baseline screenshot dimensions.
- Installation UUID, server version, OS platform, product, and server surface.

The summary scrubber removed structural patterns such as email-like tokens,
URLs, paths, domains/filenames, and long digit strings. It could not guarantee
removal of personal names or sensitive meaning expressed in ordinary words.
Historical installation aliases could also be sent to link old/new UUIDs.

This server's event allowlist dropped unknown properties; it did not allow raw
tool arguments/results, page URLs/text, screenshots, or full scripts into
ordinary PostHog tool-usage events. A separate failed-`run` reporter could send
Sentry a reduced script fingerprint, error classification, duration bucket, and
UUID, with a ten-per-day persistent budget. The fingerprint removed literals
and comments but retained identifiers/keywords. Without Sentry configuration,
it wrote reduced reports to a local daily `run-failures.log`. This reporting
used the same effective-consent gate, whose default was enabled.

### Extension/cockpit analytics and replay

The older app's `apps/app/lib/analytics/posthog.ts` enabled autocapture,
pageviews, and DOM session replay when configured, without a consent gate in
that initialization. Replay was disabled in the side panel but enabled by
configuration in other app contexts. Inputs were masked, not all DOM text.
Its configured Sentry client also enabled default PII and browser breadcrumbs.

The BrowserClaw cockpit used the server's effective analytics state and UUID.
It disabled autocapture/pageviews and stripped location/referrer properties,
but allowed explicit UI events and 20%-sampled cockpit session replay while
analytics were enabled. Replay masked inputs, blocked marked sensitive UI
regions, and omitted network bodies/headers and cross-origin iframes. This was
cockpit replay, not the separate webpage content recorder described below.

The new sinks do not initialize PostHog/session recording or Sentry, even when
credentials or previously saved consent are present. Explicit feedback,
user-submitted bug reports/waitlist submissions, and functional AI/API traffic
remain separate and unchanged. Source code cannot establish the actual deployed
host overrides, successful delivery, SDK-added wire fields, retention periods,
or access to provider-side storage.

### Local agent storage and webpage recording remain

The older server uses `.browseros` (or `.browseros-dev`) under the user's home
by default, overridable with `BROWSEROS_DIR`. Its local state includes
`db/browseros.sqlite`, session files, tool-output files, and operational logs.

The Rust server uses `.browserclaw` (or `.browserclaw-dev`), overridable with
`BROWSERCLAW_DIR`. Local state includes `analytics.json`, `browserclaw.sqlite`,
logs, screenshots, recordings, and replays. The compatibility telemetry API
still persists a local identity/preference, but neither can activate delivery.

Local MCP audit storage is richer than the remote metrics allowlist: it can
include session/client identity, tool names, tab/target IDs, URLs/titles,
bounded serialized arguments, result metadata, timings, and optional screenshots.
Argument serialization is not generally credential-redacted. Default audit
retention is seven days. These operational records are independent of PostHog
consent and have not been deleted or disabled by this change.

There is also a separate rrweb webpage recorder in
`apps/claw-app/entrypoints/recorder.content.ts`. Its content-script configuration
matches eligible main-frame URLs, starts at document load, and masks passwords
only, so other inputs and DOM content can be captured. Its batches use an
IndexedDB outbox and are relayed to the configured browser-control server,
normally local. They are not sent by the disabled PostHog sink. This functional
audit/replay mechanism remains; do not interpret "remote analytics removed"
as "no browser content is recorded locally."

## Extension control

BrowserOS had installed bundled extensions as external components, force-pinned
their toolbar actions, suppressed removal in the context menu, prohibited
disabling, and periodically re-enabled disabled product extensions. These were
product restrictions, not evidence of a real organization managing the computer.

This branch uses ordinary external-install locations, migrates the known product
extensions out of the old component location before loading them, removes
product-specific forced pinning/removal/disable restrictions, and respects
Chromium's persistent external-uninstall records. Explicit uninstall also uses
Chromium's normal data deletion instead of preserving extension storage.
Actual administrator policies and unrelated Chromium component extensions remain
unchanged. Removing the agent extension naturally makes its UI/features unavailable.

## Other restrictions and permission overrides found

The following items were found but are not changed by the extension-control work.

- Native toolbar actions can be re-pinned from BrowserOS visibility preferences in `chrome/browser/ui/toolbar/pinned_toolbar/pinned_toolbar_actions_model.cc`; the product provides visibility settings for these actions.
- Debugger-attachment warnings are suppressed for all extensions by `|| true` in `chrome/browser/extensions/api/debugger/debugger_api.cc`.
- Active product extension origins receive forced local-network access in `chrome/browser/chrome_content_browser_client.cc`.
- Product extensions have a microphone override after device-policy checks in `chrome/browser/media/extension_media_access_handler.cc`.
- Configured LLM panel provider hosts receive automatic microphone permission in `chrome/browser/ui/views/side_panel/third_party_llm/third_party_llm_panel_coordinator.cc`.
- The Windows series patch `windows-disable-download-warning-prompt.patch` changes download danger classification to not dangerous.
- BrowserOS starts a local CDP browser-control server before checking the sidecar-disable flag in `chrome/browser/browseros/server/browseros_server_manager.cc`.
- Automatic update checks are enabled without updater consent prompts in `chrome/browser/win/winsparkle_glue.cc` and `chrome/browser/mac/sparkle_glue.mm`.

These paths are relative to `chromium_patches/`, except for the Windows download
patch, which is under `series_patches/windows/ungoogled-chromium/`. No project
installation of managed-policy JSON, policy registry entries, or `SetManagedPref`
was found in the inspected build/install/patch scope. An actual machine may still
have policies supplied externally; this audit does not inspect or bypass them.

Browser/extension update downloads and local browser-control connections are
functional traffic, not inherently analytics. Disabling analytics must not be
confused with disabling the local MCP/CDP transport or preventing an agent from
sending selected content to an explicitly configured model provider.

## Verification limits

The native source-contract tests check the absence of analytics transport,
forced extension pins, automatic re-enabling, and crash upload destinations.
They also check patch syntax. The six modified/new upstream-file patches were
dry-run applied against files from the exact `BASE_COMMIT`, including the
installed-extension migration. These checks do not substitute for compiling
Chromium and testing an upgraded profile in the running browser.

The 16 focused native/build tests passed. Focused agent tests also verified that
credentials and saved consent cannot activate the disabled sinks. The full
native build-system suite was not green on this Windows machine: 1,277 tests ran,
with 32 failures, 19 errors, and 34 skips, including platform-path/mode assumptions
and missing command-line tools. No full browser compilation or installed-browser
network capture was performed.

Agent verification included 580 Rust library tests, one telemetry API test,
focused Bun/privacy tests, and the Bun server typecheck. Extension typechecks
were blocked by a missing `@browseros/diagnostics/contract` module. Broader Bun
startup tests also encountered Windows path assumptions and a default timeout.

After merging upstream, `cargo check -p claw-server` passed, as did 17 focused
error-reporting tests, 11 focused Bun/privacy tests, and the 16 focused native
tests. The expanded Rust library suite had 835 passes, three ignored tests, and
one failure in upstream's CAPTCHA connection-failure classification test. That
CAPTCHA test also failed when run alone; it was not changed as part of this work.
