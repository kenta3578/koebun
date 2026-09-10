import Foundation
import os

/// 領域別のログ（Issue #107）。
///
/// `NSLog` をやめた理由は 2 つ:
///   1. **privacy 指定ができない。** 統合ログに公開扱いで残るので、エラー文字列やファイル名に
///      口述本文が混ざった瞬間に漏れる（`swift-macos.md` §3）
///   2. Console.app で領域ごとに絞れない。すべてが 1 本の流れになる
///
/// 使い分けは「どこで起きたか」。Console.app では
/// `subsystem:com.kenta3578.koebun category:history` のように絞る。
///
/// **本文・ファイル名・エラー文字列は補間するだけで `<private>` になる**（`Logger` は
/// 非リテラルの文字列を既定で伏せる）。公開してよい固定文言や数値だけ `privacy: .public` を付ける。
enum Log {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "com.kenta3578.koebun"

    /// マイク・AVAudioEngine・リサンプリング。
    static let audio = Logger(subsystem: subsystem, category: "audio")
    /// 音声認識エンジンの読み込みと文字起こし。
    static let asr = Logger(subsystem: subsystem, category: "asr")
    /// グローバルホットキーとイベントタップ。
    static let hotkey = Logger(subsystem: subsystem, category: "hotkey")
    /// 履歴の保存・読み込み・掃除。**発話が載る唯一の領域**なので特に伏せる。
    static let history = Logger(subsystem: subsystem, category: "history")
    /// 辞書置換・フィラー語の JSON 読み書き。
    static let store = Logger(subsystem: subsystem, category: "store")
    /// 他アプリへの挿入と権限。
    static let inject = Logger(subsystem: subsystem, category: "inject")

    /// 「右⌥ を離してからカーソルに文字が入るまで」を測る（北極星の遅延 KPI）。
    ///
    /// Instruments の os_signpost で区間として見える。`durations` は履歴にも残しているが、
    /// あちらは処理ごとの内訳で、こちらは**ユーザーが待った実時間**（挿入の順番待ちを含む）。
    static let signposter = OSSignposter(subsystem: subsystem, category: "pipeline")
}
