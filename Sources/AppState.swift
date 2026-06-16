import SwiftUI

/// UI 表示用の状態。実処理は AppController が担う。
@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    @Published var isRecording = false
    @Published var modelLoaded = false
    @Published var status = "起動中…"

    private init() {}
}
