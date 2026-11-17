// Shared by the Current, Ripple, Anchor, Tide and Lighthouse documentation sites.
// Keep this file identical in every repository.
import type { Theme } from 'vitepress'
import DefaultTheme from 'vitepress/theme'
import './custom.css'

export default {
  extends: DefaultTheme,
} satisfies Theme
