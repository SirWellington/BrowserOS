/**
 * @license
 * Copyright 2025 BrowserOS
 */

interface MetricsConfig {
  install_id?: string
  browseros_version?: string
  chromium_version?: string
  server_version?: string
  [key: string]: string | undefined
}

// Compatibility sink only: no SDK, identity retention, event buffer, or timer.
// Embedded build keys and runtime environment variables cannot enable delivery.
export const metrics = {
  initialize(_config: MetricsConfig): void {},
  isEnabled(): boolean {
    return false
  },
  log(
    _eventName: string,
    _properties: Record<string, unknown> = {},
    _sampling?: number,
  ): void {},
  async shutdown(): Promise<void> {},
}
