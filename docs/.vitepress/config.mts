import { defineConfig } from 'vitepress'

const repo = 'https://github.com/kenta3578/koemakase'

// docs/ の Markdown をそのままサイトにする。ファイル名は GitHub 上のリンクと揃えたまま、
// URL だけ小文字に写す（rewrites）。
export default defineConfig({
  lang: 'ja',
  title: 'koemakase',
  description: '完全ローカルで動く、Mac 用の日本語音声入力アプリ',
  base: '/koemakase/',
  cleanUrls: true,
  lastUpdated: true,
  // docs/README.md は GitHub でフォルダを開いた人向けの目次なのでサイトには出さない
  srcExclude: ['README.md'],
  rewrites: {
    'MANUAL.md': 'manual.md',
    'PRIVACY.md': 'privacy.md',
    'ARCHITECTURE.md': 'architecture.md',
    'SWIFT-NOTES.md': 'swift-notes.md',
  },
  markdown: {
    // docs/ の外（../Tests/README.md や ../presets/engineer.json）への相対リンクはサイトに無いので、
    // GitHub 上のファイルへ向け直す。Markdown 自体は GitHub で読めるよう相対リンクのまま置いておく。
    config(md) {
      const render = md.renderer.rules.link_open
      md.renderer.rules.link_open = (tokens, idx, options, env, self) => {
        const href = tokens[idx].attrGet('href')
        if (href?.startsWith('../')) {
          tokens[idx].attrSet('href', `${repo}/blob/develop/${href.slice(3)}`)
        }
        return render ? render(tokens, idx, options, env, self) : self.renderToken(tokens, idx, options)
      }
    },
  },
  themeConfig: {
    nav: [
      { text: '説明書', link: '/manual' },
      { text: '更新履歴', link: '/changelog' },
      { text: '中の作り', link: '/architecture' },
    ],
    sidebar: [
      {
        text: '使う',
        items: [
          { text: '説明書', link: '/manual' },
          { text: '更新履歴', link: '/changelog' },
          { text: 'プライバシー', link: '/privacy' },
        ],
      },
      {
        text: '中を読む',
        items: [
          { text: '中の作り', link: '/architecture' },
          { text: '設計の根拠', link: '/design-rationale' },
          { text: '認識エンジンの計測', link: '/engine-benchmark' },
          { text: 'Web の言葉で読む Swift', link: '/swift-notes' },
        ],
      },
    ],
    outline: { level: [2, 3], label: 'このページの内容' },
    socialLinks: [{ icon: 'github', link: repo }],
    editLink: { pattern: `${repo}/edit/develop/docs/:path`, text: 'このページを GitHub で直す' },
    search: {
      provider: 'local',
      options: {
        translations: {
          button: { buttonText: '検索', buttonAriaLabel: '検索' },
          modal: {
            noResultsText: '見つかりませんでした',
            resetButtonTitle: '消す',
            footer: { selectText: '開く', navigateText: '移動', closeText: '閉じる' },
          },
        },
      },
    },
    docFooter: { prev: '前へ', next: '次へ' },
    lastUpdated: { text: '最終更新' },
    darkModeSwitchLabel: '外観',
    sidebarMenuLabel: 'メニュー',
    returnToTopLabel: '上に戻る',
  },
})
