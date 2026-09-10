import Foundation

/// 録音の世代番号と、追い越されたパイプラインが「見せ損ねた結果」（Issue #97 / #100）。
///
/// 処理中でも次の録音を始められるので、停止後のパイプラインが完了する頃には
/// 状態と HUD が次の録音のものになっていることがある。`AppController` は録音のたびに
/// `begin()` で世代を進め、パイプラインは自分の世代を控えて `finish` / `fail` に渡す。
/// 「状態と HUD を触ってよいか」「追い越されたとき何を控えるか」「控えたものをいつ出すか」の
/// 判定をここに閉じ、AppKit なしで単体で確かめられるようにしてある（Issue #102）。
struct PipelineGuard {
    /// 追い越されたパイプラインが見せ損ねた結果。
    ///
    /// 挿入できなかった結果と失敗だけを控える。成功の完了表示は控えない
    /// （挿入された文字が見えているので失われるものが無い）。
    struct Deferred: Equatable {
        struct Result: Equatable {
            var text: String
            var outcome: InsertionOutcome
        }
        var status: AppStatus
        /// HUD に残す結果。文字起こし失敗・結果パネルを出さない設定の挿入失敗なら nil。
        var result: Result?
    }

    /// パイプライン完了時に `AppController` が取るべき動き。
    enum Completion: Equatable {
        /// 現行の世代。状態と HUD を更新してよい。
        /// `replay` があれば、自分の完了表示の代わりに前のパイプラインの見せ損ねた結果を出す。
        case present(replay: Deferred?)
        /// 新しい録音に追い越された。状態・HUD に触らない（必要な結果は控えてある）。
        case superseded
    }

    /// 控えた結果の状態文に付ける前置き。複数たまっても順に出すので「前の」ではなく「以前の」。
    static let deferredLabel = "以前の発話"

    /// 現在の世代。`begin()` ごとに進む。
    private(set) var generation = 0

    /// 控えた結果。**古い順のキューで、上書きしない**（Issue #100）。
    /// 追い越しが 3 世代重なっても前の失敗が消えず、結果パネルを閉じるたびに次が出る。
    private(set) var deferred: [Deferred] = []

    /// 新しい録音の開始。進めた世代を返し、パイプラインはこれを控える。
    mutating func begin() -> Int {
        generation &+= 1
        return generation
    }

    /// その世代のパイプラインが、新しい録音に追い越されているか。
    func isSuperseded(_ generation: Int) -> Bool {
        generation != self.generation
    }

    /// 挿入まで終わったパイプラインの完了。
    ///
    /// 追い越されていれば、結果を HUD に残す表示（`.keepResult`）なら結果ごと控える。
    /// 結果パネルを出さない設定の失敗（`.hide`）は結果テキスト無しで状態だけ控える
    /// （`fail` と同じく、失敗は必ず見せる。成功の完了表示は控えない）。
    /// 現行なら、自分が結果を残す表示でない限り、控えていた結果を 1 件取り出して返す
    /// （自分も結果を残すなら新しい方を優先する。前の結果はキューに残り、閉じたときに出る）。
    mutating func finish(generation: Int,
                         status: AppStatus,
                         hud: InsertionPresentation.HUDAction,
                         text: String,
                         outcome: InsertionOutcome) -> Completion {
        if isSuperseded(generation) {
            if hud == .keepResult {
                enqueue(status: status, result: .init(text: text, outcome: outcome))
            } else if status.isFailed {
                enqueue(status: status, result: nil)
            }
            return .superseded
        }
        return .present(replay: hud == .keepResult ? nil : take())
    }

    /// 文字起こしに失敗したパイプラインの完了。失敗は必ず見せるので、追い越されていれば必ず控える。
    mutating func fail(generation: Int, status: AppStatus) -> Completion {
        if isSuperseded(generation) {
            enqueue(status: status, result: nil)
            return .superseded
        }
        return .present(replay: nil)
    }

    /// 控えた結果を古い順に 1 件取り出す。録音の破棄時に「閉じる代わりに出す」ためにも使う。
    mutating func take() -> Deferred? {
        deferred.isEmpty ? nil : deferred.removeFirst()
    }

    /// 状態文に「以前の発話」を前置きして控える。**今の発話と混ざらないようにするのが目的**なので、
    /// 前置きは控える瞬間に付ける（出すときに付けると、控えたかどうかで分岐が増える）。
    private mutating func enqueue(status: AppStatus, result: Deferred.Result?) {
        deferred.append(Deferred(status: status.prefixed(Self.deferredLabel), result: result))
    }
}
