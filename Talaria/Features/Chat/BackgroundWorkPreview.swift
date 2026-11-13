#if DEBUG
import HermesKit
import SwiftUI

/// Exercises the production status panel while the main reply is idle; never opens a socket.
struct BackgroundWorkPreview: View {
  @State private var state: BackgroundWorkState = {
    var value = BackgroundWorkState()
    value.apply(BackgroundWorkPreviewData.running)
    return value
  }()

  @State private var scheduledPoll: String?

  var body: some View {
    ThemedRoot(family: .hermes, appearance: .light) {
      NavigationStack {
        VStack(spacing: 0) {
          VStack(alignment: .leading, spacing: 18) {
            Text("Can you check the build in the background?")
              .font(AppFont.sans(15))
              .padding(14)
              .background(.indigo.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
              .frame(maxWidth: .infinity, alignment: .trailing)
            Text("The reply is finished. Background tasks continue below.")
              .font(AppFont.sans(16))
              .frame(maxWidth: .infinity, alignment: .leading)
            Text("Main reply · idle")
              .font(AppFont.sans(12))
              .foregroundStyle(.secondary)
              .accessibilityIdentifier("background.preview.main-idle")
            HStack {
              Button("Go offline") { state.markUnavailable() }
                .accessibilityIdentifier("background.preview.offline")
              Button("Reconnect") { state.apply(BackgroundWorkPreviewData.running) }
                .accessibilityIdentifier("background.preview.reconnect")
              Button("Finish tasks") { state.apply(BackgroundWorkPreviewData.finished) }
                .accessibilityIdentifier("background.preview.finish")
            }
            .buttonStyle(.bordered)
            .font(AppFont.sans(12))
            HStack {
              Button("Fail on next poll") { scheduledPoll = "failure" }
                .accessibilityIdentifier("background.preview.schedule-failure")
              Button("Lose next poll") { scheduledPoll = "unavailable" }
                .accessibilityIdentifier("background.preview.schedule-unavailable")
            }
            .buttonStyle(.bordered)
            .font(AppFont.sans(12))
          }
          .padding(16)
          Spacer(minLength: 12)
          BackgroundWorkPanelContent(state: state)
          HStack {
            Text("Message Hermes…").foregroundStyle(.secondary)
            Spacer()
            Image(systemName: "arrow.up.circle.fill").foregroundStyle(.indigo)
          }
          .padding(18)
          .background(.white, in: RoundedRectangle(cornerRadius: 20))
          .padding(.horizontal, 12)
          .padding(.bottom, 12)
        }
        .background(Color(white: 0.97))
        .navigationTitle("Background work")
        .navigationBarTitleDisplayMode(.inline)
      }
    }
    .task(id: scheduledPoll) {
      guard let scheduledPoll else { return }
      // Keep polling while the detail sheet is open, like the connected panel.
      do { try await Task.sleep(for: .seconds(5)) } catch { return }
      if scheduledPoll == "failure" { state.apply(BackgroundWorkPreviewData.failed) }
      if scheduledPoll == "unavailable" { state.markUnavailable() }
    }
  }
}

private enum BackgroundWorkPreviewData {
  static let failed = try! BackgroundWorkSnapshot(subagents: ["subagents": [[
    "subagent_id": "preview-agent", "goal": "Check the app build and report any errors", "status": "running", "started_at": 102,
  ]]], processes: ["processes": [[
    "session_id": "preview-process", "command": "swift test", "status": "exited", "exit_code": 7, "started_epoch": 101,
  ]]])

  static let running = try! BackgroundWorkSnapshot(subagents: ["subagents": [[
    "subagent_id": "preview-agent", "goal": "Check the app build and report any errors", "status": "running", "started_at": 102,
  ]]], processes: ["processes": [[
    "session_id": "preview-process", "command": "swift test", "status": "running", "started_epoch": 101,
  ]]])

  static let finished = try! BackgroundWorkSnapshot(subagents: ["subagents": []], processes: ["processes": [
    ["session_id": "preview-process", "command": "swift test", "status": "exited", "exit_code": 0, "started_epoch": 101],
    ["session_id": "preview-failed", "command": "swift test --filter ExampleTests", "status": "exited", "exit_code": 1, "started_epoch": 100],
  ]])
}
#endif
