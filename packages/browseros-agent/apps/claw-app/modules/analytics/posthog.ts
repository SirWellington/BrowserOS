/**
 * @license
 * Copyright 2025 BrowserOS
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * Automatic cockpit telemetry is hard-disabled. No SDK or recorder is loaded.
 * Configuration/sanitization helpers remain for compatibility and tests only;
 * neither build keys nor server-reported consent can activate capture.
 */

import type { PostHog, PostHogConfig } from 'posthog-js'
import { POSTHOG_HOST as HOST } from './posthog-config'

const REDACTED_REPLAY_URL = 'browserclaw://redacted'

/** Auto-added properties that could carry a url/referrer; always removed. */
const STRIPPED_PROPS = [
  '$current_url',
  '$pathname',
  '$host',
  '$referrer',
  '$referring_domain',
  '$initial_current_url',
  '$initial_pathname',
  '$initial_referrer',
  '$initial_referring_domain',
]

const captureStateListeners = new Set<() => void>()
const flagListeners = new Set<() => void>()

/**
 * The flags PostHog reported for the bootstrapped identity.
 *
 * Replaced rather than mutated on every evaluation, so a flag turned off
 * upstream disappears instead of lingering for the life of the tab.
 */
let enabledFlags: ReadonlySet<string> = new Set()

function notifyFlagListeners(): void {
  for (const listener of flagListeners) listener()
}

export function sanitizeProperties(
  properties: Record<string, unknown>,
): Record<string, unknown> {
  const cleaned = { ...properties }
  for (const key of STRIPPED_PROPS) delete cleaned[key]
  // Read the installed package at capture time: persisted super-properties can
  // outlive an extension update, while identity reset clears registered ones.
  // Web development has no extension manifest, so omit its version.
  const appVersion = globalThis.chrome?.runtime?.getManifest?.().version
  if (appVersion) cleaned.app_version = appVersion
  else delete cleaned.app_version
  return cleaned
}

/** Removes route, session, and local API identifiers from replay URLs. */
export function maskCapturedReplayRequest<T extends { name: string }>(
  request: T,
): T {
  return { ...request, name: REDACTED_REPLAY_URL }
}

export function createPostHogConfig(
  distinctId: string,
): Partial<PostHogConfig> {
  return {
    api_host: HOST,
    autocapture: false,
    capture_pageview: false,
    capture_pageleave: false,
    disable_external_dependency_loading: true,
    disable_capture_url_hashes: true,
    enable_recording_console_log: false,
    // Reconciled explicitly after effective consent is known.
    disable_session_recording: true,
    disable_surveys: true,
    // Flags gate a settings surface or two. Evaluated once when this tab
    // initialises the client, and never polled: a control that vanishes while
    // somebody is typing into it is a bug report, not a rollout.
    advanced_disable_feature_flags_on_first_load: false,
    remote_config_refresh_interval_ms: 0,
    // Do not persist browser location metadata outside the event sanitizer.
    save_campaign_params: false,
    save_referrer: false,
    // The UI never creates profiles. Server-side migration aliases can associate
    // this UUID with an existing profile containing only the linked UUIDs.
    person_profiles: 'never',
    persistence: 'localStorage',
    // Bootstrap the server's analytics.json UUID so both surfaces use the same
    // identity, including when Chromium still reports an older installation ID.
    bootstrap: { distinctID: distinctId },
    sanitize_properties: sanitizeProperties,
    session_recording: {
      blockClass: 'ph-no-capture',
      collectFonts: false,
      maskAllInputs: true,
      maskCapturedNetworkRequestFn: maskCapturedReplayRequest,
      recordBody: false,
      recordCrossOriginIframes: false,
      recordHeaders: false,
      sampleRate: 0.2,
    },
  }
}

interface RecordingConsentClient {
  opt_in_capturing(options?: { captureEventName?: string | null | false }): void
  opt_out_capturing(): void
  startSessionRecording(): void
  stopSessionRecording(): void
}

/**
 * Keeps capture consent and session recording in lockstep. Starting without
 * an override is important: it lets session_recording.sampleRate decide.
 */
export function reconcileSessionRecording(
  client: RecordingConsentClient,
  enabled: boolean,
  isInitialised: boolean,
): void {
  if (enabled) {
    // The server state is authoritative, so clear any stale SDK-local opt-out.
    // Suppress PostHog's own opt-in event; BrowserClaw sends its allowlisted one.
    client.opt_in_capturing({ captureEventName: false })
    client.startSessionRecording()
  } else if (isInitialised) {
    client.stopSessionRecording()
    client.opt_out_capturing()
  }
}

/** Records the evaluated flags and tells React. Exported for tests. */
export function applyFlags(flags: readonly string[]): void {
  enabledFlags = new Set(flags)
  notifyFlagListeners()
}

/**
 * Whether one flag is on for this install.
 *
 * Off until PostHog says otherwise, which is also the answer for a flag that
 * does not exist and for an install whose analytics are turned off and so
 * never evaluates anything. One answer for every kind of "we do not know".
 */
export function isFlagEnabled(key: string): boolean {
  return enabledFlags.has(key)
}

/** Subscribes React consumers to flag evaluations. */
export function subscribeToFlags(listener: () => void): () => void {
  flagListeners.add(listener)
  return () => flagListeners.delete(listener)
}

/**
 * A sidecar update can restore the legacy UUID while this tab stays open.
 * Stop the old replay before resetting to the server's anonymous identity;
 * the caller reapplies effective consent because reset clears SDK consent.
 * Historical A/B linking belongs to the Rust alias worker, never identify().
 */
export function reconcileTelemetryIdentity(
  client: Pick<PostHog, 'get_distinct_id' | 'stopSessionRecording' | 'reset'>,
  distinctId: string,
): void {
  if (client.get_distinct_id() === distinctId) return
  client.stopSessionRecording()
  client.reset({ bootstrap: { distinctID: distinctId, isIdentifiedID: false } })
}

/** Compatibility entry point; server settings cannot enable telemetry. */
export function applyTelemetry(_input: {
  distinctId: string
  enabled: boolean
}): void {
  // Hard-disabled independently of server consent and embedded build keys.
}

/** Capture is unavailable in this build. */
export function isCapturing(): boolean {
  return false
}

/** Subscribes React consumers to changes in effective capture readiness. */
export function subscribeToCaptureState(listener: () => void): () => void {
  captureStateListeners.add(listener)
  return () => captureStateListeners.delete(listener)
}

/** Fire-and-forget event. No-ops until capturing. */
export function capture(
  _event: string,
  _properties?: Record<string, unknown>,
): void {
  // No SDK is loaded and no events are buffered.
}
