import * as Sentry from '@sentry/react'

// Deliberately never initialize a client: no remote reports, DOM/network
// breadcrumbs, or automatic exception handlers, even when a DSN is embedded.
/** @public */
export const sentry = Sentry
