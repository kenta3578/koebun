# ビルド & 実行ガイド

署名済みバイナリはまだ配布していないので（[RELEASING.md](RELEASING.md) 参照）、現状はソースからビルドして使う。

## 前提（初回のみ）

```bash
# 1. Xcode ライセンスに同意（未同意だと swift/xcodebuild が動かない）
sudo xcodebuild -license accept

# 2. XcodeGen を入れる（project.yml から .xcodeproj を生成するツール）
brew install xcodegen
```

必要環境: Apple Silicon Mac / macOS 14.0 以降 / Xcode / 空きディスク 3GB 程度（音声認識モデル用）。

## プロジェクト生成 & 起動

```bash
git clone https://github.com/kenta3578/koebun.git
cd koebun
xcodegen generate   # project.yml → koebun.xcodeproj を生成
open koebun.xcodeproj
```

Xcode が開いたら:

1. `koebun` ターゲット → Signing & Capabilities → **Team を自分の Personal Team** に設定
2. ⌘R で実行（メニューバーにマイクアイコンが出る）

CLI でビルドだけ確認する場合:

```bash
xcodegen generate
xcodebuild -project koebun.xcodeproj -scheme koebun \
  -configuration Debug -destination 'platform=macOS' build
```

> WhisperKit の初回解決 + CoreML コンパイルで時間がかかる（数分〜十数分）。

### 依存の固定

`koebun.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved` を Git で追跡しているので、
`xcodegen generate` 後の解決はこのファイルの revision に固定される（`.xcodeproj` 自体は生成物なので `.gitignore` 済み。
このファイルだけ `!` で例外指定してある）。

依存を意図的に上げるときだけ:

```bash
xcodebuild -project koebun.xcodeproj -scheme koebun -resolvePackageDependencies
git add -f koebun.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved
```


## 開発用の署名を固定する（推奨）

`xcodebuild` の既定はアドホック署名で、**ビルドのたびに署名（cdhash）が変わる**。macOS の権限管理（TCC）は署名で同一性を判断するため、ビルドし直すたびに**アクセシビリティ権限が外れて右⌥が無反応になる**。

固定の自己署名証明書を1つ作れば、この問題は消える。**Apple Developer Program（年$99）は不要**。信頼設定（キーチェーンアクセスでの「常に信頼」）も不要で、CLI だけで完結する。

```bash
# 1. codeSigning 用途の自己署名証明書を作る（有効期限10年）
openssl req -x509 -newkey rsa:2048 -keyout koebun-dev.key -out koebun-dev.crt -days 3650 -nodes \
  -subj "/CN=koebun-dev" \
  -addext "extendedKeyUsage=critical,codeSigning" \
  -addext "basicConstraints=critical,CA:false" \
  -addext "keyUsage=critical,digitalSignature"

# 2. p12 にまとめる（macOS の security コマンドが読める形式にするため -certpbe/-keypbe/-macalg が要る。
#    OpenSSL 3 の既定（AES-256 + SHA-256 MAC）は取り込みに失敗する）
openssl pkcs12 -export -inkey koebun-dev.key -in koebun-dev.crt -out koebun-dev.p12 \
  -passout pass:koebun -name "koebun-dev" \
  -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES -macalg sha1

# 3. ログインキーチェーンへ取り込む
security import koebun-dev.p12 -k ~/Library/Keychains/login.keychain-db -P koebun \
  -T /usr/bin/codesign -T /usr/bin/security

# 4. 秘密鍵ファイルは不要になるので消す（キーチェーンに入っている）
rm -f koebun-dev.key koebun-dev.p12
```

> `security find-identity -v -p codesigning` は「0 valid identities」と表示するが、これは**信頼設定が無いだけ**で、`codesign --sign koebun-dev` は通る。TCC が見る designated requirement は
> `identifier "com.kenta3578.koebun" and certificate leaf = H"..."` になり、同じ証明書で署名する限り権限は保持される。

### 署名を切り替えた直後に「トグルを ON にしても権限が付かない」とき

アドホック署名で使っていた期間があると、システム設定のアクセシビリティ一覧に**旧署名の koebun が登録として残る**（ビルドごとに1件ずつ溜まる）。この行のトグルは旧署名にしか効かないので、`koebun-dev` で署名し直したアプリを ON にしたつもりでも権限は付かない。アプリの再起動では直らない。

一度だけ TCC の登録を消して、新署名で登録し直す:

```bash
tccutil reset Accessibility com.kenta3578.koebun   # 旧登録を全部消す
open -a koebun                                     # 起動時に権限確認ダイアログが出るので、そこから ON にする
```

以後は同じ証明書で署名し続ける限り、この作業は不要。

### `install-local.sh` の署名ステップで止まる／「署名に失敗」と出るとき

`codesign` が **キーチェーンの許可ダイアログ**（「codesign がキーチェーン内のキー koebun-dev を使用しようとしています」）を出して、その間スクリプトは無言で待つ。ダイアログを閉じたり「許可しない」を押すと署名に失敗し、**旧ビルドが動いたまま**になる（2026-09-06 に発生。10 分以上止まっていた）。

- **一時対処**: ダイアログで「常に許可」を押す。署名が続き、次回からは出ない
- **恒久対処**（ダイアログが出続ける・出ないのに失敗する）: 鍵のアクセス制御に `codesign` を登録し直す。ログインパスワードを対話で聞かれる

```bash
security set-key-partition-list -S apple-tool:,apple:,codesign: -s ~/Library/Keychains/login.keychain-db
```

原因は、Xcode の更新などで `codesign` バイナリの署名が変わり、鍵の ACL に登録された `codesign` と一致しなくなること。

## ビルドしてインストールする

```bash
./scripts/install-local.sh
```

生成 → ビルド（Release）→ `koebun-dev` があれば署名 → 起動中のアプリを終了 → `/Applications` へインストール → 起動、までを一度に行う。証明書が無い場合はアドホック署名のまま続行する（その場合は毎回アクセシビリティ権限を付け直す必要がある）。

環境変数で挙動を変えられる:

| 変数 | 既定 | 用途 |
|---|---|---|
| `KOEBUN_SIGN_IDENTITY` | `koebun-dev` | 署名に使う証明書名 |
| `KOEBUN_CONFIG` | `Release` | `Debug` にすると開発ビルド |
| `KOEBUN_DERIVED_DATA` | `.build/dd` | ビルド成果物の置き場 |

**署名を変えた直後だけは、アクセシビリティ権限を付け直す必要がある**（別の署名として扱われるため）。システム設定 → プライバシーとセキュリティ → アクセシビリティ で koebun を「−」で削除してから「+」で追加する。以降は付け直し不要になる。


## 初回実行で必要な権限

メニューバーアイコン → 各設定ボタンから許可する:

- **マイク**: 初回録音時にダイアログ。許可する
- **アクセシビリティ**: システム設定 > プライバシーとセキュリティ > アクセシビリティ で koebun を ON
  （グローバルホットキー監視 & ⌘V 合成に必須。ここを ON にしないと右⌥を押しても無反応）

> ビルドし直すとバイナリが変わるため、アクセシビリティの許可が効かなくなることがある。
> その場合は一覧から koebun を削除して登録し直す。

## 使い方

- **右 ⌥（Option）を押すと録音開始、もう一度押すと停止**（押しっぱなしではなくトグル）
- 停止すると文字起こし → 辞書置換 → 最前面アプリのカーソル位置に挿入、の順で処理される
- メニューバーアイコンの形状と色で状態が分かる（読込=黄/砂時計、待機=マイク、録音=赤、処理=青/波形、完了=緑、エラー=橙）。クリックすれば文言でも読める
- 開始音・停止音・トリガーキー・辞書置換ルールはメニューバー →「設定…」から変更できる
  （置換ルールの実体は `~/koebun/replacements.json`）

## セキュリティ補足

- **完全ローカル**: `Sources/` の Swift コードにネットワーク送信処理は無い。音声・文字起こしテキストはメモリ内で完結し、ログ/ファイルにも出さない（ディスクに書くのは置換ルールと設定値のみ）
- **唯一の通信**: WhisperKit の初回モデル DL（Hugging Face から CoreML モデルを `~/Library/Caches/argmaxinc/whisperkit-coreml/openai_whisper-large-v3` へ取得、約 2.9GB）。2 回目以降はオフラインで動く
- **サンドボックス OFF**: Accessibility / CGEvent / グローバル監視のため。この判断は `project.yml` にコメントで残している
- **配布する場合**: `ENABLE_HARDENED_RUNTIME` を `YES` に戻し、Developer ID 署名 + Notarization が必要。手順は [RELEASING.md](RELEASING.md)

## 既知の調整ポイント

- WhisperKit の API が変わってビルドが通らない場合は `Sources/Transcriber.swift` の `transcribe` 呼び出し／`WhisperKitConfig` を最新シグネチャに合わせる
- ホットキーは設定 UI から変更できる。選択肢そのものを増やすなら `Sources/SettingsStore.swift`
- モデルを軽く/速くするなら `Sources/Transcriber.swift` の `model: "large-v3"` を `"large-v3-turbo"` 等に変更
