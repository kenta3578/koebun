import Foundation

/// 音声認識・整形の**実装を差し替えられるようにする**ための境界（Issue #27）。
///
/// 目的は「Apple 標準に寄せる」ことではなく、**同じ発話を両方に通して実測で決める**こと。
/// 現状は WhisperKit large-v3（約2.9GB）＋ Qwen3 14B/4bit（約9GB）で初回12GB を要求するが、
/// macOS 26 は SpeechAnalyzer と Foundation Models を OS 内蔵で持っている。
/// どちらが良いかは日本語・実利用で測るまで分からないので、**既存実装は消さずに並べる**。
///
/// 比較の一次データは履歴（`HistoryEntry`）に残る。どのエンジンで処理したかを保存しているので、
/// 生テキスト・整形後・所要時間・`FormatDiff` の警告をエンジン別に突き合わせられる。

// MARK: - エンジンの種類

/// 音声認識エンジンの選択肢。UserDefaults と履歴には `rawValue` が入る。
enum SpeechEngineKind: String, CaseIterable, Identifiable, Sendable {
    /// WhisperKit large-v3。初回に HuggingFace から約2.9GB を取得してメモリに常駐させる。
    case whisperKit
    /// Apple SpeechAnalyzer（macOS 26 以降）。認識モデルは OS 側のアセットで、
    /// **アプリのダウンロードは発生しない**。
    case apple

    var id: String { rawValue }

    /// 設定画面のピッカーに出す文言。
    var label: String {
        switch self {
        case .whisperKit: return "WhisperKit large-v3（約2.9GB を DL・既定）"
        case .apple:      return "Apple 音声認識（macOS 26・DL 無し）"
        }
    }

    /// 履歴に出す短い名前。
    var shortLabel: String {
        switch self {
        case .whisperKit: return "WhisperKit"
        case .apple:      return "Apple"
        }
    }

    /// この環境で選べるか。Apple 実装は macOS 26 以降でしか動かない。
    var isSupported: Bool {
        switch self {
        case .whisperKit:
            return true
        case .apple:
            if #available(macOS 26.0, *) { return true }
            return false
        }
    }
}

/// 整形エンジンの選択肢。
enum FormattingEngineKind: String, CaseIterable, Identifiable, Sendable {
    /// mlx-swift（MLXLLM）で Qwen3 を常駐させる。14B/4bit で約9GB。
    case mlx
    /// Apple Foundation Models（macOS 26 以降のオンデバイス約3B）。常駐もダウンロードも無い。
    case apple

    var id: String { rawValue }

    var label: String {
        switch self {
        case .mlx:   return "Qwen3（mlx-swift 常駐・既定）"
        case .apple: return "Apple Foundation Models（macOS 26・DL 無し）"
        }
    }

    var shortLabel: String {
        switch self {
        case .mlx:   return "Qwen3"
        case .apple: return "Apple"
        }
    }

    var isSupported: Bool {
        switch self {
        case .mlx:
            return true
        case .apple:
            if #available(macOS 26.0, *) { return true }
            return false
        }
    }
}

/// エンジンが使えない理由の共通文言。ピッカーを disable するだけでは何も伝わらないので添える。
enum EngineSupport {
    static let requiresMacOS26 = "macOS 26 以降が必要です"
}

// MARK: - 共通の型

/// 整形エンジンの読み込み状態。UI にはこれを文字列化して出す。
///
/// mlx 実装は数GB のダウンロードを伴うので `loading` が長く続く。
/// Apple 実装は OS 内蔵なので、可用性を確かめて `ready` か `failed` に即決する。
enum EngineLoadState: Equatable, Sendable {
    case notLoaded
    /// ダウンロード／読み込み中。`fraction` は 0...1、不明なら nil。
    case loading(modelId: String, fraction: Double?)
    case ready(modelId: String)
    case failed(reason: String)
}

/// 整形の結果。
struct FormattedText: Sendable {
    var text: String
    /// 実際に送ったシステムプロンプト全文。履歴に残して整形を検証できるようにする。
    var prompt: String
    /// 使ったモデルの識別子。mlx なら HuggingFace の repo id、Apple なら固定の識別子。
    var modelId: String
}

// MARK: - プロトコル

/// 音声認識エンジン。実装は actor（`Transcriber` = WhisperKit / `AppleTranscriber` = SpeechAnalyzer）。
///
/// **どちらの実装も同じ入力を受ける**契約にする——`AudioRecorder` が作る
/// 16kHz / mono / Float32 の `[Float]`。比較のとき入力側が揃っていないと意味が無い
/// （履歴の `audio.wav` もこの形式で保存されるので、あとから同じ音声を再投入できる）。
protocol SpeechEngine: Sendable {
    /// 認識の準備をする。WhisperKit は約2.9GB のダウンロードと常駐、
    /// Apple は OS 内蔵アセットの確認だけで、アプリ側のダウンロードは発生しない。
    func load() async throws
    /// 常駐を解除してメモリを返す。エンジンを切り替えたときに呼ぶ
    /// （両方載せたままだと、比較したい常駐メモリが測れない）。
    func unload() async
    /// 16kHz / mono / Float32 サンプルを日本語テキストに変換する。
    func transcribe(_ samples: [Float]) async throws -> String
}

/// 整形エンジン。実装は actor（`Formatter` = mlx-swift / `AppleFormatter` = Foundation Models）。
///
/// 呼び出し側の契約は既存のまま: **このエンジンが失敗しても発話は失われない**。
/// `AppController` は例外を握って置換後テキストを挿入し、理由を `AppStatus` に出す。
protocol FormattingEngine: Sendable {
    /// 整形の準備をする。`modelId` を使うのは自前でモデルを持つ実装だけで、
    /// Apple 実装は OS 内蔵なので無視する（可用性の確認だけを行う）。
    func load(modelId: String, onProgress: @Sendable @escaping (EngineLoadState) -> Void) async throws
    /// 常駐を解除してメモリを返す。
    func unload() async
    /// `text` を `mode` のプロンプトで整形する。`timeout` を超えたら投げる。
    func format(
        _ text: String,
        mode: Mode,
        contextBlock: String?,
        timeout: Duration
    ) async throws -> FormattedText
}
