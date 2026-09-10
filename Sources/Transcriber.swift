import Foundation
import os
@preconcurrency import WhisperKit

enum TranscriberError: Error {
    case notReady
}

/// WhisperKit ラッパー。large-v3 を日本語で文字起こしする。
/// モデル（約2.9GB）は初回ロード時にダウンロードされる。
///
/// `SpeechEngine` の実装の1つ（Issue #27）。**挙動は差し替え前と同じ**で、
/// 切り替えのために `unload()` だけを足してある。
actor Transcriber: SpeechEngine {
    private var pipe: WhisperKit?

    /// 使うモデルの variant 名。
    static let model = "large-v3"

    /// モデルをロードする。**無ければダウンロードする。**
    ///
    /// 以前は `modelFolder` にキャッシュのパスを渡していたが、WhisperKit は
    /// `modelFolder` が非 nil だと**ダウンロード分岐に入らない**
    /// （`if let folder = modelFolder { ... } else if download { ...ダウンロード... }`）。
    /// 開発機には既にキャッシュがあったので気づかれないまま、他人が WhisperKit を選ぶと
    /// 2.9GB は永久に落ちてこず、録音のたびに `modelsUnavailable` になっていた（Issue #83）。
    ///
    /// `modelFolder` を渡さないと `load` の既定が false になる（`config.load ??
    /// (config.modelFolder != nil)`）ので、明示的に true にする。既にキャッシュがあれば
    /// HubApi が既存ファイルを見るので再ダウンロードは走らない。
    func load() async throws {
        let config = WhisperKitConfig(model: Self.model, load: true, download: true)
        // まず取得（既にあれば HubApi が既存ファイルを見るので走らない）。
        let pipeline = try await WhisperKit(config)
        // **読み込んだ後ではなく、使う前に照合する。** WhisperKit には revision を渡す口が
        // 無く main を追い続けるので、書き換えられたら黙って別の重みを読む（Issue #106）。
        // 一致しなければ throw して、この pipe を使わせない。
        try Self.verifyDownloadedModel()
        pipe = pipeline
    }

    /// キャッシュ上のモデルを記録と照合する。同じマニフェストで一度通っていれば読み飛ばす。
    private static func verifyDownloadedModel() throws {
        guard let directory = modelDirectory else { return }
        do {
            try ModelIntegrity.verify(directory: directory)
        } catch {
            Log.asr.error("モデルの照合に失敗しました: \(error.localizedDescription)")
            throw error
        }
    }

    /// キャッシュ上のモデルディレクトリ。`.cachesDirectory` が引けなければ nil。
    private static var modelDirectory: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("argmaxinc/whisperkit-coreml/openai_whisper-\(model)")
    }

    /// モデルが既にダウンロード済みか。UI に「ダウンロード中」を出すかの判断に使う。
    ///
    /// `.cachesDirectory` は OS がパージしうるので、消えていれば取得からやり直す。
    static var hasCachedModel: Bool {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        else { return false }
        // 一式のうち1つでも欠けると `loadModels` が modelsUnavailable を投げるので、
        // 代表として MelSpectrogram の有無を見る。
        _ = caches
        guard let probe = modelDirectory?.appendingPathComponent("MelSpectrogram.mlmodelc")
        else { return false }
        return FileManager.default.fileExists(atPath: probe.path)
    }

    /// 常駐を解除してメモリ（約2.9GB）を返す。Apple 音声認識へ切り替えたときに呼ぶ。
    func unload() {
        pipe = nil
    }

    /// 16kHz mono Float サンプルを日本語テキストに変換する。
    func transcribe(_ samples: [Float]) async throws -> String {
        guard let pipe else { throw TranscriberError.notReady }
        guard !samples.isEmpty else { return "" }

        let options = DecodingOptions(task: .transcribe, language: "ja")
        let results = try await pipe.transcribe(audioArray: samples, decodeOptions: options)

        return results
            .map { $0.text }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
