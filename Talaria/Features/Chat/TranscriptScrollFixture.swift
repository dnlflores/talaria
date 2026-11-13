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
    ThemedRoot(family: .hermes, appearance: .dark) {
      NavigationStack {
        ChatView(chat: chat)
      }
    }
    .environment(app)
  }
}
#endif
