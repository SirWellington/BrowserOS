# C:\chromium privacy audit and supervised build

## Scope and status

This is a source/build-configuration audit, not proof of historical network
traffic. No browser history, cookies, saved passwords, or personal page contents
were inspected. The installed browser has not been replaced, and old output
binaries must not be treated as the result of this build.

On 2026-10-22 the checkout at `C:\chromium\src` was on Chromium 151, commit
`8f5d36bc16f57115aeeff34baf4ad6aa964d509c`, with an older BrowserOS patch set.
The project now pins Chromium `155.0.8059.26` and a newer BrowserOS patch base.
The build is being run with source-built agent resources, `CORE_ONLY=yes`, and
signing/upload disabled. Completion and runtime traffic verification are pending.

Before updating source, tracked and untracked local changes were preserved in
Chromium's Git stash as `db1a40103f9d8776d6f0643254caabafe2302145`.
The release preset's initial clean step subsequently removed generated outputs
and dependency caches. The wrapper now defaults to `--no-clean` and supports
verified `RESUME_FROM` checkpoints to avoid repeating that cleanup. Do not restore the old patch set over
the new checkout just to resume compilation; it contains the prior telemetry code.

The Chromium 155 checkout initially stopped on an obsolete nested
`third_party/aria-practices/src` Git checkout, whose files are owned by the main
repository in the new pin. Its tracked state was clean; the entire old repository
was moved, not deleted, to
`C:\chromium\.browseros-checkout-backups\before-155.0.8059.26\third_party\aria-practices\src`.

The source-built native MCP server completed and was staged as version `0.0.77`
for `windows-x64`, with source revision
`2ea06075962849bd2e181c13fbcc7dfade8e68b3`. Both staged resource hashes matched
their artifact metadata; the server executable's SHA-256 is
`2900cd1b9440a4cd40a57711ce8eecfa483b87fd3c9ed611e606e2f19ce54277`.
The locally built onboarding assets also completed. This is not completion of
the native browser or installer.

A `--from source_sync` attempt was refused by the checkpoint validator because
exact published-component pins were unavailable. That check was not bypassed;
the next attempt uses the complete plan with `--no-clean`.

The complete-plan retry successfully checked out Chromium commit
`16c3e55476d3564bea713314b2fff638749ce3e6` for the supported 155 pin.
Dependency synchronization is still running; this does not yet establish a
fully synchronized or privacy-patched source tree.

## Findings in the old patched tree

The old `chrome/browser/browseros/metrics/` implementation had a process-wide
PostHog sender, persistent installation identity, event queue, and network
dependencies. It assembled version/OS/architecture/product/installation-linked
payloads and accepted caller-supplied event properties. There was no consent gate.

Both native `chrome/app/chrome_crash_reporter_client*.cc` implementations forced
crash-upload consent to true, and the product provided a Sentry minidump URL.
These were transmission-capable source paths, not evidence that a particular
installed executable successfully sent a particular payload.

The current repository removes the native sender and its identity generator,
leaves an inert metrics compatibility API, and makes crash consent false with
an empty upload URL. These changes must be checked in the final applied source
and resulting executable, not inferred from a pristine upstream checkout.

## Upstream Chromium barriers and remaining capability

- Non-Google-branded Chromium ordinarily disables metrics reporting in `components/metrics/metrics_service_accessor.cc`; a force-enable switch is an exception.
- The inspected public Chromium metrics resources use empty UMA/UKM/DWA/private-metrics destinations in `components/metrics/server_urls.grd` and normalize them to empty URLs in `server_urls.cc`.
- The old generated build flags selected Chromium rather than Google Chrome branding and did not include official Google API credentials. New generated outputs still need verification.
- URL-keyed metrics consent defaults to false in `components/unified_consent/unified_consent_service.cc`, but history-sync transitions can enable that preference. UKM code can retain HTTP(S) paths and queries if enabled; the word “anonymized” is not proof that only a domain is collected.
- Standard Safe Browsing and background operation have their own defaults and networking. Security/update traffic is not automatically analytics, but an endpoint sees connection metadata. These mechanisms must not be described as “no networking whatsoever.”

Thus the upstream tree contains telemetry capabilities even where branding,
consent, and destination barriers normally prevent delivery. This audit does not
claim every upstream networking feature has been removed.

The shared `series_patches/series` file contains only examples/comments; it is
not a general ungoogled-chromium privacy patch set. The Windows series includes
platform fixes and a patch that suppresses download danger classification.
Do not infer broad Google-service removal or stock download-warning behavior
from the project's README description. The download-warning patch remains a
separate security concern, not a telemetry fix.

## Browser-core-only mode selected for this build

The user selected a browser core without vendor extension bundles rather than
generating new extension signing identities. `build.bat` now defaults to
`CORE_ONLY=yes`, which passes `browseros_core_only=true` to GN.

- The extension staging step does not fetch vendor CRXs and clears stale generated bundles from incremental outputs.
- GN exposes an empty bundled-extension target, and native code does not start the product extension discovery/recovery provider.
- Extension-backed routes and the onboarding handoff are inactive; the native MCP server remains source-built.
- Known packed product extensions in an upgraded profile are disabled without deleting their data. Unpacked extensions and actual enterprise-policy locations are left intact.
- Runtime product overrides and packaging of other products' server resources are disabled.
- Cached downloaded sidecars are not probed or selected; the source-built bundled sidecar is used instead.
- The native sidecar updater and Windows WinSparkle initialization are disabled, preventing those paths from replacing the locally modified build with vendor binaries.
- Both supported depot_tools collection environment switches are set to zero, independently of runtime browser analytics.

This mode does not audit arbitrary third-party extensions a user installs or
organization policy controls. It also does not suppress functional data exchange
with a model provider or website that a user explicitly chooses to use.

## Verification gates

All 47 tests across source provisioning, source-cache handling, the Windows
wrapper, extension staging, and native source contracts pass. They include a
test that core-only staging makes no manifest fetch
and removes stale generated CRXs. These are not end-to-end browser tests.

Before calling the build privacy-verified, check all of the following.

1. The final checkout and dependencies match the supported Chromium pin, and every required BrowserOS patch applies.
2. Generated GN arguments/build flags select core-only mode, Chromium branding, and the local server only.
3. Applied source contains the no-op native metrics API, false crash consent, and empty upload destinations, with no stale sender source in the build graph.
4. Browser output and installer contain no vendor extension CRXs or alternate vendor server bundles.
5. The packaged native sidecar is attributable to this source build and cannot activate analytics or automatic error reporting.
6. A disposable profile is used for launch/idle/control-path traffic checks; no normal user profile is opened for testing.

Until these gates are complete, the build is in progress and is not a guarantee
that no personal information can ever leave a browser under any configuration.
