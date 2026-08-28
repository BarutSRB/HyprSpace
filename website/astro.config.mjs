// @ts-check
import { defineConfig } from 'astro/config';
import starlight from '@astrojs/starlight';

export default defineConfig({
  site: 'https://omniwm.app',
  integrations: [
    starlight({
      title: 'OmniWM',
      logo: {
        src: './src/assets/brand/omniwm-logo.svg',
        alt: 'OmniWM',
        replacesTitle: true,
      },
      favicon: '/favicon.svg',
      social: [{ icon: 'github', label: 'GitHub', href: 'https://github.com/BarutSRB/OmniWM' }],
      editLink: { baseUrl: 'https://github.com/BarutSRB/OmniWM/edit/main/website/' },
      lastUpdated: true,
      customCss: ['./src/styles/theme.css'],
      head: [
        { tag: 'link', attrs: { rel: 'icon', href: '/favicon.ico', sizes: 'any' } },
        { tag: 'link', attrs: { rel: 'icon', href: '/favicon-32x32.png', sizes: '32x32', type: 'image/png' } },
        { tag: 'link', attrs: { rel: 'icon', href: '/favicon-16x16.png', sizes: '16x16', type: 'image/png' } },
        { tag: 'link', attrs: { rel: 'apple-touch-icon', href: '/apple-touch-icon.png', sizes: '180x180' } },
        { tag: 'link', attrs: { rel: 'mask-icon', href: '/safari-pinned-tab.svg', color: '#763424' } },
        { tag: 'meta', attrs: { name: 'theme-color', content: '#F8F4EC' } },
        { tag: 'meta', attrs: { property: 'og:site_name', content: 'OmniWM' } },
        { tag: 'meta', attrs: { property: 'og:image', content: 'https://omniwm.app/og.png' } },
        { tag: 'meta', attrs: { name: 'twitter:card', content: 'summary_large_image' } },
        {
          tag: 'script',
          content:
            'addEventListener("DOMContentLoaded",()=>{for(const t of document.querySelectorAll(".sl-markdown-content table"))if(t.scrollWidth>t.clientWidth)t.tabIndex=0;});',
        },
      ],
      sidebar: [
        { label: 'Getting Started', items: [{ autogenerate: { directory: 'guides' } }] },
        { label: 'Features', items: [{ autogenerate: { directory: 'features' } }] },
        { label: 'Configuration', items: [{ autogenerate: { directory: 'config' } }] },
        { label: 'CLI & IPC', items: [{ autogenerate: { directory: 'reference/cli' } }] },
        { label: 'Help', items: [{ autogenerate: { directory: 'help' } }] },
        { label: 'Developers', items: [{ autogenerate: { directory: 'developers' } }] },
      ],
    }),
  ],
});
