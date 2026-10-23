import { expect, it, mock } from 'bun:test'

const construct = mock(() => {
  throw new Error('Automatic analytics must not construct a client')
})
mock.module('posthog-node', () => ({ PostHog: construct }))
mock.module('../../src/env', () => ({
  INLINED_ENV: { POSTHOG_API_KEY: 'test-key' },
}))

const { metrics } = await import('../../src/lib/metrics')

it('never enables, constructs, buffers, or flushes analytics with a build key', async () => {
  metrics.initialize({ install_id: 'test-install', server_version: 'test' })
  for (const event of ['mcp.request', 'tool_executed', 'server_started']) {
    metrics.log(event, { tool_name: 'run', success: false }, 1)
  }
  expect(metrics.isEnabled()).toBe(false)
  await metrics.shutdown()
  metrics.initialize({ install_id: 'another-install' })
  expect(metrics.isEnabled()).toBe(false)
  expect(construct).not.toHaveBeenCalled()
})
