import { defineConfig } from 'vitepress'
import { family } from './theme/family'

const shared = family('tide', '/Tide/')

export default defineConfig({
  ...shared.config,

  lang: 'en-US',
  title: 'Tide',
  description: 'Replication for moving things on Roblox: player characters, bots and NPCs on one server timeline.',

  themeConfig: {
    ...shared.themeConfig,

    nav: [
      { text: 'Guide', link: '/guide/getting-started', activeMatch: '^/guide/' },
      { text: 'Reference', link: '/reference/api', activeMatch: '^/reference/' },
      { text: 'Benchmarks', link: '/benchmarks' },
      shared.nav,
      {
        text: 'v0.1.0',
        items: [{ text: 'Releases', link: 'https://github.com/Acidgorgon/Tide/releases' }],
      },
    ],

    sidebar: [
      {
        text: 'Guide',
        items: [
          { text: 'Getting started', link: '/guide/getting-started' },
          { text: 'Players', link: '/guide/players' },
          { text: 'Bots and NPCs', link: '/guide/entities' },
          { text: 'Time and rewind', link: '/guide/time-and-rewind' },
          { text: 'Interest and bandwidth', link: '/guide/interest' },
          { text: 'Security', link: '/guide/security' },
          { text: 'Migrating from Chrono', link: '/guide/migrating-from-chrono' },
        ],
      },
      {
        text: 'Reference',
        items: [
          { text: 'API', link: '/reference/api' },
          { text: 'Config', link: '/reference/config' },
          { text: 'Wire format', link: '/reference/wire-format' },
        ],
      },
      { text: 'Benchmarks', items: [{ text: 'Results', link: '/benchmarks' }] },
    ],

    socialLinks: [{ icon: 'github', link: 'https://github.com/Acidgorgon/Tide' }],

    editLink: {
      pattern: 'https://github.com/Acidgorgon/Tide/edit/main/docs/:path',
      text: 'Edit this page on GitHub',
    },
  },
})
