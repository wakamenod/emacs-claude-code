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
			description:
				'Run the Claude Code CLI inside Emacs. Conversations, permission prompts, diffs, and plans live in ordinary Emacs buffers — no terminal emulator required.',

			// Starlight writes og:title, og:description and a summary_large_image
			// twitter:card by itself, but no image; without one the card is an
			// empty box.  The picture is in public/, so the URL carries the base
			// and has to be absolute here.
			head: [
				{
					tag: 'meta',
					attrs: {
						property: 'og:image',
						content:
							'https://wakamenod.github.io/emacs-claude-code/og.png',
					},
				},
				{ tag: 'meta', attrs: { property: 'og:image:width', content: '1200' } },
				{ tag: 'meta', attrs: { property: 'og:image:height', content: '630' } },
				{
					tag: 'meta',
					attrs: {
						property: 'og:image:alt',
						content:
							'An ecc session in Emacs: source code on the left, transcript with an approved edit on the right',
					},
				},
				{
					tag: 'meta',
					attrs: {
						name: 'twitter:image',
						content:
							'https://wakamenod.github.io/emacs-claude-code/og.png',
					},
				},
			],

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
					label: 'Start here',
					translations: { ja: 'はじめに' },
					items: [{ autogenerate: { directory: 'start' } }],
				},
				{
					label: 'Features',
					translations: { ja: '機能' },
					items: [{ autogenerate: { directory: 'features' } }],
				},
				{
					label: 'Reference',
					translations: { ja: 'リファレンス' },
					items: [{ autogenerate: { directory: 'reference' } }],
				},
			],
		}),
	],
});
