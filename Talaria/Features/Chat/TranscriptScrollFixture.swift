#if DEBUG
import SwiftUI

/// Exercises the real transcript, navigation bars and composer without credentials or a server.
struct TranscriptScrollFixture: View {
  @State private var app: AppModel
  @State private var chat: ChatModel

  init() {
    let app = AppModel()
    _app = State(initialValue: app)
    _chat = State(initialValue: ChatModel.scrollPreview(
      app: app, short: ProcessInfo.processInfo.arguments.contains("--short-chat")))
  }

  var body: some View {
    let appearance = ProcessInfo.processInfo.environment["TALARIA_PREVIEW_APPEARANCE"]
    ThemedRoot(family: .hermes, appearance: appearance.flatMap(AppearanceMode.init(rawValue:)) ?? .dark) {
      NavigationStack {
        ChatView(chat: chat)
      }
      // As over the real app, so what a chat says in a toast shows here too.
      .overlay { ToastOverlay() }
    }
    .environment(app)
    .task {
      // `--live-turns`: running turns stream in after the chat has settled at the bottom.
      guard ProcessInfo.processInfo.arguments.contains("--live-turns") else { return }
      let delay = Double(ProcessInfo.processInfo.environment["TALARIA_LIVE_TURNS_DELAY"] ?? "") ?? 1.5
      try? await Task.sleep(for: .seconds(delay))
      let pace = Int(ProcessInfo.processInfo.environment["TALARIA_LIVE_TURNS_PACE_MS"] ?? "") ?? 60
      await chat.playPreviewTurns(count: 2, pace: .milliseconds(pace))
    }
  }
}
#endif
