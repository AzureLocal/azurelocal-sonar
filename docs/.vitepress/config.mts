import { defineConfig } from 'vitepress'

export default defineConfig({
  ignoreDeadLinks: true,
  base: '/azurelocal-sonar/',
  title: 'AzL Sonar',
  description: 'Real-time monitor for Azure Local deployments: live steps, status and deployment logs.',
  themeConfig: {
    nav: [
      { text: 'Home', link: '/' },
      { text: 'Getting started', link: '/getting-started' },
      { text: 'How it works', link: '/how-it-works' },
      { text: 'Plan', link: '/plan' }
    ],
    sidebar: [
      { text: 'Home', link: '/' },
      { text: 'Getting started', link: '/getting-started' },
      { text: 'How it works', link: '/how-it-works' },
      { text: 'Plan', link: '/plan' }
    ],
    socialLinks: [
      { icon: 'github', link: 'https://github.com/AzureLocal/azurelocal-sonar' }
    ],
    footer: {
      message: 'Released under the MIT License.',
      copyright: 'Copyright © Hybrid Cloud Solutions & AzureLocal'
    }
  }
})
