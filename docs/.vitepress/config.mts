import { defineConfig } from 'vitepress'

export default defineConfig({
  ignoreDeadLinks: true,
  base: '/azurelocal-sonar/',
  title: 'AzL Sonar',
  description: 'Real-time monitor for Azure Local deployments: live steps, status and deployment logs.',
  head: [
    ['link', { rel: 'icon', type: 'image/svg+xml', href: '/azurelocal-sonar/assets/images/azurelocal-sonar-icon.svg' }]
  ],
  themeConfig: {
    logo: '/assets/images/azurelocal-sonar-icon.svg',
    nav: [
      { text: 'Home', link: '/' },
      { text: 'Getting started', link: '/getting-started' },
      { text: 'How it works', link: '/how-it-works' },
      { text: 'Plan', link: '/plan' }
    ],
    sidebar: [
      { text: 'Home', link: '/' },
      { text: 'Start here', link: '/start-here' },
      { text: 'Getting started', link: '/getting-started' },
      { text: 'Running Sonar, by purpose', link: '/run' },
      { text: 'Running Sonar, stage by stage', link: '/stages' },
      { text: 'Log access', link: '/log-access' },
      { text: 'Configuration', link: '/config' },
      { text: 'Tour of the page', link: '/tour' },
      { text: 'Following a ZTP run', link: '/ztp' },
      { text: 'How it works', link: '/how-it-works' },
      { text: 'Design', link: '/design' },
      { text: 'Research and live findings', link: '/research' },
      { text: 'Plan', link: '/plan' },
      {
        text: 'Appendix',
        items: [
          { text: 'A. Sonar API and commands', link: '/appendix/a-sonar-api' },
          { text: 'B. Configurator app API', link: '/appendix/b-configurator-app-api' }
        ]
      }
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
