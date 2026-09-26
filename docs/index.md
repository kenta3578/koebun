---
layout: home

hero:
  name: sarari
  text: さらり
  tagline: 完全ローカルで動く、Mac 用の日本語音声入力アプリ。右 ⌥ を押して話し、もう一度押すと、カーソル位置に文字が入ります。
  actions:
    - theme: brand
      text: 説明書を読む
      link: /manual
    - theme: alt
      text: 更新履歴
      link: /changelog
    - theme: alt
      text: GitHub
      link: https://github.com/kenta3578/sarari

features:
  - title: 端末の外に出さない
    details: 認識は macOS 内蔵の音声認識。音声もテキストも送信せず、録音した音声はディスクにも残しません。
    link: /privacy
    linkText: 根拠を見る
  - title: ダウンロード 0
    details: macOS 26 以降ならモデルのダウンロードは要りません。英数字や URL が多いときだけ WhisperKit に切り替えられます。
  - title: 同じ入力から同じ結果
    details: 辞書置換・フィラー除去・？補完は、LLM を使わない決まった文字列処理です。
    link: /manual#辞書置換
    linkText: 辞書置換を見る
---
