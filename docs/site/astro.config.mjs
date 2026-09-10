// @ts-check
import { defineConfig } from 'astro/config';
import starlight from '@astrojs/starlight';

// https://astro.build/config
export default defineConfig({
	// A GitHub project page: the origin is the user site and the repository
	// name is the base.  `base` takes a leading slash and no trailing one --
	// get it wrong and the HTML still loads while every asset 404s.
	site: 'https://wakamenod.github.io',
	base: '/emacs-claude-code',

	integrations: [
		starlight({
			title: 'ecc',
			description: 'An Emacs client for the Claude Code CLI.',

			// English lives at the root and Japanese under /ja/, which mirrors
			// README.md and README.ja.md: the English one is the source of
			// record and the Japanese one follows it.
			defaultLocale: 'root',
			locales: {
				root: { label: 'English', lang: 'en' },
				ja: { label: '日本語', lang: 'ja' },
			},

			social: [
				{
					icon: 'github',
					label: 'GitHub',
					href: 'https://github.com/wakamenod/emacs-claude-code',
				},
			],

			// Starlight appends the page path relative to this Astro project
			// root, so the base has to end in docs/site/.
			editLink: {
				baseUrl:
					'https://github.com/wakamenod/emacs-claude-code/edit/main/docs/site/',
			},

			lastUpdated: true,

			sidebar: [
				{
					label: 'Reference',
					translations: { ja: 'リファレンス' },
					autogenerate: { directory: 'reference' },
				},
			],
		}),
	],
});
