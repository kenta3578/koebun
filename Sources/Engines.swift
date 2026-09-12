import Foundation

/// 音声認識・整形の**実装を差し替えられるようにする**ための境界（Issue #27）。
///
/// 目的は「Apple 標準に寄せる」ことではなく、**同じ発話を両方に通して実測で決める**こと。
/// どちらが良いかは日本語・実利用で測るまで分からないので、**既存実装は消さずに並べる**。
///
/// 実測（1台1回・Issue #31）の結果、**既定は Apple 音声認識**に決めた。
/// 認識は Apple 292ms / WhisperKit 3,906ms で、Apple は句読点まで自前で付けてくる。
/// ただし Apple は URL・メール・英数字を毎回違う壊し方で崩すので、そこが要る発話のために
/// WhisperKit を残す（`docs/engine-benchmark.md` §2）。
///
/// 整形 LLM は #62 の判定で削除した（#131）。用途が言えるのは WhisperKit だけ、という整理。
///
/// 比較の一次データは履歴（`HistoryEntry`）に残る。

// MARK: - エンジンの種類

/// 音声認識エンジンの選択肢。UserDefaults と履歴には `rawValue` が入る。
enum SpeechEngineKind: String, CaseIterable, Identifiable, Sendable {
    /// WhisperKit large-v3。初回に HuggingFace から約2.9GB を取得してメモリに常駐させる。
    /// macOS 26 未満での既定。
    case whisperKit
    /// Apple SpeechAnalyzer（macOS 26 以降）。認識モデルは OS 側のアセットで、
    /// **アプリのダウンロードは発生しない**。macOS 26 以降での既定。
    case apple

    var id: String { rawValue }

    /// 設定画面のピッカーに出す文言。
    var label: String {
        switch self {
        case .whisperKit: return "WhisperKit large-v3（約2.9GB を DL）"
        case .apple:      return "Apple 音声認識（macOS 26・DL 無し・既定）"
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

/// エンジンが使えない理由の共通文言。ピッカーを disable するだけでは何も伝わらないので添える。
enum EngineSupport {
    static let requiresMacOS26 = "macOS 26 以降が必要です"
}

// MARK: - 共通の型

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
