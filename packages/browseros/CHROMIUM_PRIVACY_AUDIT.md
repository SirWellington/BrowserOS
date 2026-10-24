# C:\chromium privacy audit and supervised build

## Scope and status

This is a source/build-configuration audit, not proof of historical network
traffic. No browser history, cookies, saved passwords, or personal page contents
were inspected. The installed browser has not been replaced, and old output
binaries must not be treated as the result of this build.

On 2026-10-22 the checkout at `C:\chromium\src` was on Chromium 151, commit
`8f5d36bc16f57115aeeff34baf4ad6aa964d509c`, with an older BrowserOS patch set.
The project now pins Chromium `155.0.8059.26` and a newer BrowserOS patch base.
The build is configured for source-built agent resources, `CORE_ONLY=yes`, and
signing/upload disabled. Chromium compilation and runtime traffic verification
are pending.

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

The complete-plan retry checked out Chromium commit
`16c3e55476d3564bea713314b2fff638749ce3e6` for the supported 155 pin. The first
dependency-sync attempt failed after upstream returned HTTP 429 fetching
`third_party/vulkan-tools/src`. A second attempt progressed further, then CIPD
stopped while opening the cached Chromium package
`chromium/third_party/updater/chrome_win_x86`; the local security scanner
reported that the instance contained a virus or potentially unwanted software
(label `Trojan:Win32/Suschil!rfn`). The build was not allowed to bypass that
block, disable security protection, or omit the dependency, and no Windows
Defender exclusion was added.

The Suschil detection was assessed as very likely a false positive: it is a
heuristic label with no documented malware family, the flagged file was never
executed (`DidThreatExecute=False`), and the CIPD instance chain was verified as
official — the `chrome_win_x86` instance was registered by Chromium's builder
service account with a SLSA attestation, and CIPD instance IDs encode the
zip's SHA-256. Because the hit was a heuristic label on a package the 64-bit
build never uses, the chosen fix was to stop fetching it, not to suppress the
scanner.

`packages/browseros/tools/patch_deps_updater.py` (wired into `build.bat` before
`browseros build`, with regression tests) idempotently drops the eight unused
32-bit/arm64 Windows updater CIPD entries from `C:\chromium\src\DEPS` and keeps
the four `x86_64` entries the 64-bit installer needs. With the patch applied,
`source_sync` completed successfully (282.0s); the HTTP 429 and the
security-scanner stall did not recur, and the remaining CIPD packages verified
cleanly. This workaround is committed as `63a0b395e`.

The build then failed at the next step, `windows_sdk`: Chromium 155 is pinned to
Windows SDK `10.0.28000.2270` (family `10.0.28000.0`) with x86/x64 Desktop C++
and Debugging Tools, and the machine has only `10.1.26100.7705` registered.
Local builds check for the SDK but do not install it; installing it is a
machine-wide, elevated operation the build cannot perform. Once the SDK is
installed, `build.bat` must be rerun — ninja resumes from the `windows_sdk`
step and proceeds through `compile`, `mini_installer`, and `package_windows`.
Configuration, compilation, and runtime traffic verification are therefore
still pending. On 2026-10-24, verification gates 1–5 were run as a read-only
inspection against the current checkout and the staged resources (results in
"Verification gates" below); gate 6 remains pending on this blocker.

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

## Evaluated alternative: ungoogled-chromium plus a built-in MCP server

As a potential replacement, ungoogled-chromium was forked locally to
`C:\Users\moreno\Documents\Code\WellingtonHQ\EDI\ungoogled-chromium` (main repo:
110 patches tracking Chromium `156.0.8078.47`; Windows repo:
`...\WellingtonHQ\EDI\ungoogled-chromium-windows`, 27 additional
patches). A design for shipping a built-in MCP server comparable to BrowserOS
neo was written to
`C:\Users\moreno\Documents\Code\WellingtonHQ\EDI\DESIGN-builtin-mcp-server.md`.
It recommends a native Rust sidecar (`EDI`) launched by the browser,
owning a loopback CDP connection (via `--remote-debugging-port=0` and the
`DevToolsActivePort` file) and exposing the same tool surface as neo — the same
architecture class as neo's `claw-server` — with an estimated effort of about
4–5 months for one engineer. This is a design proposal, not a built or tested
replacement. Since that assessment, the base browser was built locally from
the forked ungoogled-chromium (Chromium `156.0.8078.47`) and a CDP attach
probe passed: the browser launches with `--remote-debugging-port=0` on a
disposable profile, the ephemeral port is discovered via the
`DevToolsActivePort` file, and `http://127.0.0.1:<port>/json/version`
answers over loopback with the expected browser identity — the exact
mechanism EDI's `runtime.json` will use. The EDI sidecar itself is not yet
implemented.

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

### Gate results (2026-10-24, read-only inspection)

Gates 1–5 were evaluated against the current checkout
(`C:\chromium\src` at `16c3e55476d3564bea713314b2fff638749ce3e6`) and the
staged resources. No build was run, no file was modified, and no browser was
launched.

1. **Checkout/dependencies/patches — PASS.** The checkout is at the pinned
   commit. All 407 patches (402 from `packages/browseros/chromium_patches`
   plus the 5 in `series_patches/series.windows`) reverse-apply cleanly
   (`git apply --check -R`), i.e. every required patch is applied. The
   working-tree state is fully accounted for: patch-derived changes, the DEPS
   edit that drops the eight unused 32-bit/arm64 updater CIPD blocks (the
   `63a0b395e` wrapper change), the branding step, and staged resources.
2. **Generated GN args — PASS.** `out\Default_browserclaw_x64\args.gn` sets
   `browseros_core_only=true`, `browseros_product = "browserclaw"`,
   `browseros_allow_runtime_product_override = false`,
   `browseros_package_all_server_resources = false`, and empty Google API
   credentials (`google_api_key=""`, `use_official_google_api_keys=false`).
   Generated flags confirm Chromium branding
   (`BUILDFLAG_INTERNAL_CHROMIUM_BRANDING() == 1`) and core-only
   (`BUILDFLAG_INTERNAL_BROWSEROS_CORE_ONLY() == 1`); the server-resources
   target copies only the source-built `claw_server/resources`.
3. **Applied source — PASS.** `BrowserOSMetrics::Log` is an empty
   compatibility entry point whose GN target carries no network deps; both
   crash-reporter clients return consent `false` and an empty upload URL. A
   source-wide search of `chrome/` found no sender code: one comment-only
   PostHog hit, and one dead `kSentryMinidumpUrl` constant (see findings).
   Core-only gates confirmed in source: empty bundled-extension group,
   WinSparkle `Initialize()` refused, sidecar `StartUpdater()` refused,
   runtime product override compiled out.
4. **Vendor extensions — PASS.** Core-only staging performed no manifest
   fetch and no CRX download;
   `chrome/browser/browseros/bundled_extensions/` contains only `BUILD.gn`
   and an empty `bundled_extensions.json`; no
   `out\Default_browserclaw_x64\browseros_extensions` directory exists; no
   vendor CRXs anywhere under `chrome/` or `out/`.
5. **Staged native sidecar — PASS.** The staged 0.0.77 `windows-x64` server
   exe hashes to the recorded value, is byte-identical to the copy staged
   into the Chromium tree, and every staged artifact matches its
   `artifact-metadata.json`. The binary carries the 0.0.77 version marker and
   no PostHog/Sentry strings. The source (`claw-server`) has an inert
   analytics service, a no-op startup reporter, and Sentry/PostHog code
   excluded from release builds; the metadata `sourceSha` matches the agent
   repo HEAD, and the commits between the staged revision and HEAD touched no
   Rust server source.
6. **Traffic checks — PENDING.** Blocked on the `windows_sdk` step (no
   compiled browser exists); a disposable-profile launch/idle/control-path
   check cannot run until the SDK is installed and the build completes.

### Staged artifact hashes (SHA-256, 2026-10-24)

| Artifact | SHA-256 |
|---|---|
| `browseros-claw-server.exe` (staged, and byte-identical tree copy) | `2900cd1b9440a4cd40a57711ce8eecfa483b87fd3c9ed611e606e2f19ce54277` |
| `skills/browserclaw/SKILL.md` (staged, and byte-identical tree copy) | `e28c53dda7e7e90d9fee6c234624f4cf142b3d62c6e8c81b4e4f5b82e7d50ea6` |
| onboarding `app.css` | `b92944672ec94c399dd978b4eef4dfd8da0ce7396b63a26eb69e97c2b274e489` |
| onboarding `app.js` | `35076a5e5058fd8732c7bed11176b6d27d23dd01e7ab5110a9231ec51c5b7b98` |
| onboarding `index.html` | `875a4b281f35efce067f4454722c7f854fdbb04e513b85e3d1cdab96e5202c19` |
| onboarding `icon/16.png` | `256d00e322b934b8f831712ae5b1e977c30351a9a37fcad26f2c95d3fbadb210` |
| onboarding `icon/32.png` | `09c4814ebb8811ec07f9fc6b80b6a4d6e8c4cc4ff991ffe6f1f2410ac7219e5a` |
| onboarding `icon/48.png` | `e155421f1b65b2924795d512351f1c6288cf8b3d399cec6245ce0540e18b9862` |
| onboarding `icon/96.png` | `2ee57fe408cb807aeaa073ce76a98b27b3d4aba9737a8951f1affd53b4497b30` |
| onboarding `icon/128.png` | `bb49ab0d9cb87ff1ef3a1d9cc308bee4aac069230b462f8b7de11bcdd4a42a51` |
| onboarding `icon/keychain-prompt.png` | `6fd993093d750a2eb17172b0c26df72681d47827c3bc22ce06cc16570a8d26c3` |

(Staging roots: `packages/browseros/resources/binaries/browseros_claw_server_rust/windows-x64/`
and `packages/browseros/resources/binaries/browseros_onboarding/`.)

### Findings from the gate run

- **Dead Sentry DSN in applied source.**
  `chrome/browser/browseros/core/browseros_constants.h:237-241` defines
  `kSentryMinidumpUrl` with a live-looking Sentry ingest DSN and key. It is
  referenced nowhere (the real upload URL is empty in both crash clients), so
  it is not a transmission path — but it is a credential sitting in source.
  Recommended: remove it from the patch that introduces the constants
  header.
- **Stale source-revision record.** This document previously recorded the
  staged server's source revision as `2ea06075962849bd2e181c13fbcc7dfade8e68b3`;
  the artifact metadata records `sourceSha: 6947ecb66291b62c0556494a12852be7e1e2af1e`
  (the agent repo HEAD). The two differ by four commits, none of which
  touched Rust server source, so the exe is attributable to the current tree;
  the metadata value is the accurate record.
- **Vendored WinSparkle binaries.** `third_party/sparkle/` and
  `third_party/winsparkle/` (including prebuilt `WinSparkle.dll`/`.lib`) are
  untracked, wrapper-vendored, and referenced by patched BUILD files. They
  are inert in this build: core-only refuses WinSparkle initialization before
  the DLL loads.
- **`enable_winsparkle=true` in args.gn** only decides whether the glue code
  is compiled; the core-only runtime check is what disables it.
- **Browser-side OTA design remains in source.**
  `browseros_server_config.cc` still contains vendor appcast URLs and an
  updater descriptor, gated off by core-only in this build. A future
  non-core-only build from this tree would re-enable the vendor sidecar
  updater; that is a scoping note, not a defect of this build.

Until these gates are complete, the build is in progress and is not a guarantee
that no personal information can ever leave a browser under any configuration.
