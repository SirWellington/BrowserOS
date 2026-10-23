import { describe, expect, it } from 'bun:test'

const root = `${import.meta.dir}/../..`

function isolated(source: string): void {
  const result = Bun.spawnSync(
    [process.execPath, '--no-env-file', '-e', source],
    {
      cwd: root,
      env: {
        ...process.env,
        SENTRY_DSN: 'https://test@sentry.invalid/1',
        VITE_PUBLIC_SENTRY_DSN: 'https://test@sentry.invalid/1',
        VITE_PUBLIC_POSTHOG_KEY: 'test-key',
        VITE_PUBLIC_POSTHOG_HOST: 'https://telemetry.invalid',
        VITE_CLAW_POSTHOG_KEY: 'test-key',
      },
      stdout: 'pipe',
      stderr: 'pipe',
    },
  )
  expect(result.stderr.toString()).toBe('')
  expect(result.exitCode).toBe(0)
}

describe('automatic telemetry cannot be activated by credentials or consent', () => {
  it('does not initialize either Sentry client', () => {
    isolated(`
      import { Sentry } from './apps/server/src/lib/sentry';
      import { sentry } from './apps/app/lib/sentry/sentry';
      if (Sentry.getClient() || sentry.getClient()) throw Error('Sentry initialized');
      Sentry.captureException(new Error('test'));
      sentry.captureException(new Error('test'));
    `)
  })

  it('keeps both extension analytics sinks inert without network or DOM APIs', () => {
    isolated(`
      import { posthog } from './apps/app/lib/analytics/posthog';
      import { track } from './apps/app/lib/metrics/track';
      import { BrowserOSAdapter } from './apps/app/lib/browseros/adapter';
      import { applyTelemetry, isCapturing, capture } from './apps/claw-app/modules/analytics/posthog';
      globalThis.fetch = () => { throw Error('Unexpected analytics network request'); };
      posthog.capture('test', { private: 'must not buffer' });
      posthog.identify('test-install');
      posthog.reset();
      track('test', { private: 'must not forward to native telemetry' });
      globalThis.chrome = { browserOS: { logMetric() { throw Error('Native telemetry called'); } } };
      await BrowserOSAdapter.getInstance().logMetric('test');
      for (const enabled of [true, false, true]) {
        applyTelemetry({ distinctId: 'test-install', enabled });
        capture('test');
        if (isCapturing()) throw Error('Capture enabled');
      }
      if (posthog.__loaded) throw Error('PostHog loaded');
    `)
  })
})
