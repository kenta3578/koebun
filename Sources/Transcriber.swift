import Foundation
import WhisperKit

enum TranscriberError: Error {
    case notReady
}

/// WhisperKit ラッパー。large-v3 を日本語で文字起こしする。
/// 初回ロード時にモデル（約2.9GB）が自動ダウンロードされる。
///
/// `SpeechEngine` の実装の1つ（Issue #27）。**挙動は差し替え前と同じ**で、
/// 切り替えのために `unload()` だけを足してある。
actor Transcriber: SpeechEngine {
    private var pipe: WhisperKit?

    /// モデルをロード（ローカルキャッシュを優先）。
    func load() async throws {
        let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let modelFolder = cacheDir
            .appendingPathComponent("argmaxinc/whisperkit-coreml/openai_whisper-large-v3")
        let config = WhisperKitConfig(
            model: "large-v3",
            modelFolder: modelFolder.path
        )
        pipe = try await WhisperKit(config)
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
