import type { FC, PropsWithChildren } from 'react'

/**
 * @public
 */
export const AnalyticsProvider: FC<PropsWithChildren> = ({ children }) => {
  // Preserve the layout boundary without loading an analytics SDK or context.
  return <>{children}</>
}
