import CryptoKit
import Foundation

/// ダウンロードした WhisperKit のモデル重みが、**開発時に確かめたものと同じか**を照合する
/// （Issue #106）。
///
/// ## なぜ revision 固定ではないのか
///
/// WhisperKit 0.18.0 には revision を渡す口が無い（`WhisperKitConfig` にも
/// `WhisperKit.download(variant:)` にも無く、ソース全体を検索しても `revision` は 0 件）。
/// `argmaxinc/whisperkit-coreml` の `main` を必ず追うので、**ブランチが書き換えられたら
/// 黙って別の重みを読む**。
///
/// ## なぜ HuggingFace の API から期待値を取らないのか
///
/// 2 つの理由で取らない:
///
/// 1. **循環する。** 検証したい相手（HF）から期待値を取っても、重みを差し替えられる攻撃者は
///    同じ場所のメタデータも差し替えられる。意味のある検証にならない
/// 2. **「ネットワーク送信処理が存在しない」という検証可能な主張を壊す。** README は
///    通信 API の名前を `Sources/` へ grep してヒットが 0 件であることを根拠に、完全ローカルを
///    説明している（パターンは README 側にある。**ここに書くとこのファイルが引っかかる**）。
///    通信を足せばその根拠そのものが消える
///
/// ## この検証が保証すること・しないこと
///
/// - **する**: 開発時に確かめた重みから**あとで変わった**ことの検知（＝上の脅威そのもの）
/// - **しない**: 最初に取得した重みが本物かどうか。マニフェストは実機のキャッシュから
///   起こしているので、そこは trust on first use のまま
///
/// マニフェストの作り直しは `scripts/model-manifest.sh`。
enum ModelIntegrity {

    /// 照合する 1 ファイル。パスはモデルディレクトリからの相対。
    struct Entry {
        let path: String
        let sha256: String
        let size: Int
    }

    enum VerificationError: LocalizedError {
        case missing(String)
        case sizeMismatch(String)
        case digestMismatch(String)

        var errorDescription: String? {
            switch self {
            case .missing(let path):
                return "モデルのファイルが足りません（\(path)）。取得し直してください。"
            case .sizeMismatch(let path), .digestMismatch(let path):
                return "モデルの内容が記録と一致しません（\(path)）。"
                     + "取得元が更新されたか、ファイルが壊れています。"
            }
        }
    }

    /// `openai_whisper-large-v3` の全 19 ファイル。2026-09-10 に実機のキャッシュから起こした。
    /// 更新するときは `scripts/model-manifest.sh` の出力で丸ごと差し替える。
    static let largeV3: [Entry] = [
        .init(path: "AudioEncoder.mlmodelc/analytics/coremldata.bin", sha256: "195e35e9fbaa218cd59eca69988a2165245e5bfccc4a5d9776847e8955d1625a", size: 243),
        .init(path: "AudioEncoder.mlmodelc/coremldata.bin", sha256: "273d6cd004f95763e9d03e5d36622f11038819a81b9eafed64b1d95444e04f62", size: 348),
        .init(path: "AudioEncoder.mlmodelc/metadata.json", sha256: "db0d80a1046e03e211928cd2918d5e5924947f4ecbcee5232b125f0f59757fbc", size: 1826),
        .init(path: "AudioEncoder.mlmodelc/model.mil", sha256: "3e7737df445ef8fc13238970e3e518c0c6455bcadb6371df2ede1f22dcb8a8e0", size: 581035),
        .init(path: "AudioEncoder.mlmodelc/model.mlmodel", sha256: "bf0987c0d8c3fe180877b12ba5b4ac1d890e011f2103926e53186089feced575", size: 408667),
        .init(path: "AudioEncoder.mlmodelc/weights/weight.bin", sha256: "eb07bab32dcd62ce653b5b288bd6c27bdc5a538be309f242e33ed05e1cb53457", size: 1273974400),
        .init(path: "config.json", sha256: "798b69c08cf93b2b03d94bea6eb3eb25fd4712259712d8a62ed2483fdf818a9e", size: 1163),
        .init(path: "generation_config.json", sha256: "d24f9cca0f448609a71ae044b736023706382f45e9700e0dffb2559d10cf1fea", size: 2810),
        .init(path: "MelSpectrogram.mlmodelc/analytics/coremldata.bin", sha256: "091a361134891f94e613562771beea0d93a9aefbc6984ba86c60f856e07a508f", size: 243),
        .init(path: "MelSpectrogram.mlmodelc/coremldata.bin", sha256: "f3c5778c86d6fbc6a9817a56dbcac05a946a4d95c77f6db8355572f3be9e9a68", size: 329),
        .init(path: "MelSpectrogram.mlmodelc/metadata.json", sha256: "1a94f4dfaec25549cbb386fe59b68c67a7a5af4a1c672a5998e5a84b9111135b", size: 1850),
        .init(path: "MelSpectrogram.mlmodelc/model.mil", sha256: "17977ed2332430c6cc4c1da2516f2cd4deb662d65ae38d72725ab157f32d4949", size: 10187),
        .init(path: "MelSpectrogram.mlmodelc/weights/weight.bin", sha256: "97a66b915cd3fc97dcba6806d92381e1a56024b8f68c1a1cd370d4c92505fe87", size: 373376),
        .init(path: "TextDecoder.mlmodelc/analytics/coremldata.bin", sha256: "7c151c6259c279aa7922d60e82c7851bbad1df10018b1cebc566aa6c2aee5e0f", size: 243),
        .init(path: "TextDecoder.mlmodelc/coremldata.bin", sha256: "f41a7939b47f7cf127aa69dfd8c552a141dc773b936bf8621aeffcd201fb9e30", size: 637),
        .init(path: "TextDecoder.mlmodelc/metadata.json", sha256: "de900a968f7640e9775c28268e348a0bc6559a4a92defae07d91e7effa838246", size: 4770),
        .init(path: "TextDecoder.mlmodelc/model.mil", sha256: "f8273cbf61aac4a43118a9090fc4d580678ea04abda473b4cb9dda2647d25c27", size: 1010477),
        .init(path: "TextDecoder.mlmodelc/model.mlmodel", sha256: "680d8dfb7c7d8f1f852071ac7bdc96e55c696d0b822e70861045efb426b0a27b", size: 745579),
        .init(path: "TextDecoder.mlmodelc/weights/weight.bin", sha256: "680f398925225a313c62da0221aa0a58c9f1bffac5c36f20c449a70a7c9b1e55", size: 1813201716),
    ]

    /// このマニフェストの版。中身が変われば値も変わるので、**差し替えたら自動的に再検証**される。
    static func manifestDigest(_ entries: [Entry]) -> String {
        var hasher = SHA256()
        for entry in entries.sorted(by: { $0.path < $1.path }) {
            hasher.update(data: Data("\(entry.path):\(entry.sha256):\(entry.size)\n".utf8))
        }
        return hex(hasher.finalize())
    }

    /// 検証済みを覚えておくキー。2.9GB のハッシュは数秒かかるので毎回は回さない。
    private static let verifiedKey = "verifiedModelManifest"

    /// モデルディレクトリを照合する。**一致しなければ throw**（呼び出し側が読み込みを止める）。
    ///
    /// 同じマニフェストで一度通っていれば読み飛ばす。マニフェストを差し替えると
    /// 版が変わるので、次回に必ずもう一度回る。
    static func verify(directory: URL,
                       entries: [Entry] = largeV3,
                       defaults: UserDefaults = .standard) throws {
        let digest = manifestDigest(entries)
        if defaults.string(forKey: verifiedKey) == digest { return }

        for entry in entries {
            let url = directory.appendingPathComponent(entry.path)
            guard let size = try? FileManager.default
                .attributesOfItem(atPath: url.path)[.size] as? Int else {
                throw VerificationError.missing(entry.path)
            }
            // 先にサイズを見る。違えば 1.7GB を読まずに落とせる。
            guard size == entry.size else { throw VerificationError.sizeMismatch(entry.path) }
            guard try sha256(of: url) == entry.sha256 else {
                throw VerificationError.digestMismatch(entry.path)
            }
        }
        defaults.set(digest, forKey: verifiedKey)
    }

    /// ファイル全体を読み込まずに SHA-256 を取る（weight.bin は 1.7GB ある）。
    private static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 4 * 1024 * 1024), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hex(hasher.finalize())
    }

    private static func hex(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}
