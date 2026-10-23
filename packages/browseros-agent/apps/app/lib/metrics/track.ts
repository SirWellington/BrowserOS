/** @public */
export function track(
  _eventName: string,
  _properties?: Record<string, unknown>,
): void {
  // Do not gather version metadata or forward events to native browser telemetry.
}
