#!/usr/bin/env bash
# koebun をローカルにビルドして /Applications へインストールする。
#
# アドホック署名（xcodebuild の既定）だと**ビルドのたびに署名が変わる**ため、
# macOS はそれを別のアプリと見なし、アクセシビリティ権限が毎回リセットされる。
# 開発中はこれが致命的に煩わしいので、固定の自己署名証明書 (koebun-dev) があれば
# それで署名し直してからインストールする。証明書が無ければアドホックのまま続行する。
#
# 証明書の作り方は BUILD.md の「開発用の署名を固定する」を参照。
set -euo pipefail

IDENTITY="${KOEBUN_SIGN_IDENTITY:-koebun-dev}"
CONFIG="${KOEBUN_CONFIG:-Release}"
APP_DEST="/Applications/koebun.app"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED="${KOEBUN_DERIVED_DATA:-$REPO_ROOT/.build/dd}"

cd "$REPO_ROOT"

echo "==> プロジェクトを生成"
xcodegen generate >/dev/null

echo "==> ビルド ($CONFIG)"
xcodebuild -project koebun.xcodeproj -scheme koebun -configuration "$CONFIG" \
  -derivedDataPath "$DERIVED" -destination 'platform=macOS' build >/dev/null

APP_SRC="$DERIVED/Build/Products/$CONFIG/koebun.app"
[ -d "$APP_SRC" ] || { echo "ビルド成果物が見つからない: $APP_SRC" >&2; exit 1; }

if security find-certificate -c "$IDENTITY" >/dev/null 2>&1; then
  echo "==> $IDENTITY で署名（権限を保持するため）"
  codesign --force --deep --sign "$IDENTITY" "$APP_SRC"
else
  echo "==> $IDENTITY が無いのでアドホック署名のまま（起動のたびに権限を取り直す必要あり）"
fi

echo "==> 起動中の koebun を終了"
osascript -e 'tell application "koebun" to quit' 2>/dev/null || true
sleep 1

echo "==> $APP_DEST へインストール"
# ditto は既存バンドルへ上書きコピーする（消えたファイルは残るので、
# 構成が変わったときは APP_DEST を手で消してから実行する）。
ditto "$APP_SRC" "$APP_DEST"

echo "==> 署名の確認"
codesign -dvv "$APP_DEST" 2>&1 | grep -E "Authority|Signature" || true

echo "==> 起動"
open -a "$APP_DEST"
echo "完了"
