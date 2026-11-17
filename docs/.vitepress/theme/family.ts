// Shared by the Current, Ripple, Anchor, Tide and Lighthouse documentation sites.
// Keep this file identical in every repository: per-site settings live in config.mts.
import type { DefaultTheme, HeadConfig, UserConfig } from 'vitepress'

export type Library = 'current' | 'ripple' | 'anchor' | 'tide' | 'lighthouse'

export interface Member {
  name: string
  role: string
  site: string
}

export const FAMILY: Record<Library, Member> = {
  current: { name: 'Current', role: 'Networking', site: 'https://acidgorgon.github.io/Current/' },
  ripple: { name: 'Ripple', role: 'State sync', site: 'https://acidgorgon.github.io/Ripple/' },
  anchor: { name: 'Anchor', role: 'Data saving', site: 'https://acidgorgon.github.io/Anchor/' },
  tide: { name: 'Tide', role: 'Motion', site: 'https://acidgorgon.github.io/Tide/' },
  lighthouse: { name: 'Lighthouse', role: 'Profiling', site: 'https://acidgorgon.github.io/Lighthouse/' },
}

const ORDER: Library[] = ['current', 'ripple', 'anchor', 'tide', 'lighthouse']

// The accent colour of each site is the one CSS variable --lib-accent, set here from the
// presets in custom.css (--accent-current, --accent-ripple, --accent-anchor, --accent-tide, --accent-lighthouse).
const THEME_COLOR: Record<Library, string> = {
  current: '#0a64a8',
  ripple: '#08767c',
  anchor: '#1c3a80',
  tide: '#5b3fa8',
  lighthouse: '#9c5a00',
}

/** Name of the library family (Acid, 2026-11-17). */
export const FAMILY_NAME = 'Harbor'

/** The family dropdown for the top navigation bar. */
export function familyNav(self: Library): DefaultTheme.NavItemWithChildren {
  return {
    text: FAMILY_NAME,
    items: ORDER.map((id) => ({
      text: `${FAMILY[id].name} · ${FAMILY[id].role}`,
      link: FAMILY[id].site,
      target: '_self',
    })),
  }
}

/** Footer shown on pages without a sidebar (the home page). */
export interface FamilyOptions {
  /** License named in the footer, e.g. 'MIT' or 'Apache-2.0'. Defaults to 'MIT'. */
  license?: string
}

export function familyFooter(self: Library, options: FamilyOptions = {}): DefaultTheme.Footer {
  const links = ORDER.map((id) =>
    id === self ? `<strong>${FAMILY[id].name}</strong>` : `<a href="${FAMILY[id].site}">${FAMILY[id].name}</a>`,
  ).join(' · ')
  return {
    message: `Part of ${FAMILY_NAME}, a family of Roblox libraries: ${links}. Released under the ${options.license ?? 'MIT'} license.`,
  }
}

/**
 * Everything the family sites share: head tags (favicon, accent, theme colour), appearance,
 * code highlighting, search and page chrome. Spread `config` into defineConfig and
 * `themeConfig` into its themeConfig, then add the site's own nav, sidebar and links.
 *
 * `base` must equal the site's `base` (for example '/current/').
 */
export function family(self: Library, base: string, options: FamilyOptions = {}) {
  const head: HeadConfig[] = [
    ['link', { rel: 'icon', type: 'image/svg+xml', href: `${base}family/${self}.svg` }],
    ['meta', { name: 'theme-color', content: THEME_COLOR[self] }],
    ['style', {}, `:root { --lib-accent: var(--accent-${self}); }`],
  ]

  const config: UserConfig<DefaultTheme.Config> = {
    base,
    head,
    appearance: true,
    cleanUrls: true,
    lastUpdated: true,
    markdown: {
      theme: { light: 'github-light', dark: 'github-dark' },
      lineNumbers: false,
    },
  }

  const themeConfig: DefaultTheme.Config = {
    logo: { src: `/family/${self}.svg`, alt: FAMILY[self].name },
    search: { provider: 'local' },
    outline: { level: [2, 3], label: 'On this page' },
    footer: familyFooter(self, options),
    docFooter: { prev: 'Previous', next: 'Next' },
    externalLinkIcon: true,
  }

  return { config, themeConfig, nav: familyNav(self) }
}
