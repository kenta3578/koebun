#!/usr/bin/env bash
# WhisperKit のモデル重みのマニフェスト（Issue #106）を、いま手元にあるキャッシュから起こす。
#
# 出力を Sources/ModelIntegrity.swift の `largeV3` に丸ごと貼り替える。
# **貼り替えると版（manifestDigest）が変わるので、次回の起動で必ず再検証が走る。**
#
# 使うのは「WhisperKit を上げた」「モデルを変えた」「取得元の更新を意図して受け入れる」とき。
# 差分が意図しないものなら、それがこの Issue が検知したかった事象そのもの。
set -euo pipefail

MODEL="${1:-large-v3}"
DIR="$HOME/Library/Caches/argmaxinc/whisperkit-coreml/openai_whisper-$MODEL"

if [ ! -d "$DIR" ]; then
  echo "モデルのキャッシュがありません: $DIR" >&2
  echo "設定 › 一般 › 音声認識 で WhisperKit を選んで取得してから実行してください。" >&2
  exit 1
fi

echo "    static let largeV3: [Entry] = ["
cd "$DIR"
find . -type f | sort | while read -r f; do
  rel="${f#./}"
  printf '        .init(path: "%s", sha256: "%s", size: %s),\n' \
    "$rel" \
    "$(shasum -a 256 "$f" | cut -d' ' -f1)" \
    "$(stat -f%z "$f")"
done
echo "    ]"
