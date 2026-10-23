/**
 * @license
 * Copyright 2025 BrowserOS
 */

import * as Sentry from '@sentry/bun'

// Never initialize a client or install automatic error/breadcrumb integrations.
// Existing capture call sites are inert without a client, regardless of build keys.

export { Sentry }
