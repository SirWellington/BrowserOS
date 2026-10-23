import type { PostHog } from 'posthog-js'

// Keep the provider/capture interface without loading the SDK, its recorder,
// persisting an identity, buffering events, or making any network requests.
export const posthog = {
  capture: () => undefined,
  identify: () => undefined,
  reset: () => undefined,
  register: () => undefined,
  getFeatureFlag: () => undefined,
  isFeatureEnabled: () => false,
  onFeatureFlags: () => () => undefined,
  __loaded: false,
} as unknown as PostHog
