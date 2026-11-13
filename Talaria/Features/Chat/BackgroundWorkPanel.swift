import HermesKit
import SwiftUI

/// Read-only status for this exact stored chat; independent of main-turn streaming.
struct BackgroundWorkPanel: View {
  let profile: String
  let storedID: String

  var body: some View {
    if !profile.isEmpty, !storedID.isEmpty {
      BackgroundWorkLivePanel(scope: .init(profile: profile, storedID: storedID))
        .id(BackgroundWorkScope(profile: profile, storedID: storedID))
    }
  }
}

private struct BackgroundWorkLivePanel: View {
  let scope: BackgroundWorkScope
  @Environment(AppModel.self) private var app
  @Environment(\.scenePhase) private var scenePhase
  @State private var model = BackgroundWorkModel()

  private struct PollKey: Hashable {
    let active: Bool
    let client: ObjectIdentifier?
  }

  var body: some View {
    // Keep a mounted lifecycle host even when an empty successful read hides the strip.
    VStack(spacing: 0) {
      BackgroundWorkPanelContent(state: model.state, isChecking: !model.hasChecked && !model.state.isUnavailable)
    }
      .task(id: PollKey(active: scenePhase == .active, client: app.client.map(ObjectIdentifier.init))) {
        guard scenePhase == .active else {
          model.pause()
          return
        }
        let client = app.client
        await model.run(scope: scope) {
          guard let client else { throw BackgroundWorkError.invalidResponse }
          return try await client.backgroundWork(profile: scope.profile, storedID: scope.storedID)
        }
      }
      .onChange(of: scenePhase) { _, phase in
        if phase != .active { model.pause() }
      }
      .onDisappear { model.pause() }
  }
}

/// Shared by the connected panel and the deterministic, network-free preview.
struct BackgroundWorkPanelContent: View {
  let state: BackgroundWorkState
  var isChecking = false
  @Environment(\.palette) private var palette
  @State private var expanded = false
  private struct SelectedTask: Identifiable { let id: String }
  @State private var selected: SelectedTask?

  private var running: [BackgroundWorkItem] { state.rows.filter { $0.status.isRunning } }
  private var summary: String {
    if state.isUnavailable { return "Background work · status unavailable" }
    if isChecking { return "Background work · checking…" }
    return state.summary
  }

  var body: some View {
    // A clean empty read needs no permanent strip. Errors are never hidden as empty work.
    if !state.rows.isEmpty || state.isUnavailable {
      VStack(alignment: .leading, spacing: 8) {
        Button {
          withAnimation(.easeInOut(duration: 0.18)) { expanded.toggle() }
        } label: {
          HStack(spacing: 8) {
            Image(systemName: state.isUnavailable ? "wifi.exclamationmark" : "square.stack.3d.up")
              .foregroundStyle(palette.primaryText)
            Text(summary)
              .font(AppFont.sans(13, .semibold))
              .foregroundStyle(palette.foreground)
              .multilineTextAlignment(.leading)
            Spacer(minLength: 4)
            Image(systemName: expanded ? "chevron.up" : "chevron.down")
              .font(.caption.weight(.semibold))
              .foregroundStyle(palette.foregroundMuted)
          }
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(summary)
        .accessibilityIdentifier("background.summary")
        .accessibilityHint(expanded ? "Hide task history" : "Show tasks and recent results")

        if state.isUnavailable {
          Text(state.hasSnapshot
            ? "Status unavailable. Last checked: \(state.runningCount) running. Retrying…"
            : "Status unavailable. Retrying…")
            .font(AppFont.sans(12))
            .foregroundStyle(palette.foregroundMuted)
            .fixedSize(horizontal: false, vertical: true)
        }

        if expanded {
          ScrollView {
            VStack(spacing: 10) {
              ForEach(state.rows) { row in taskRow(row) }
            }
          }
          .frame(maxHeight: 180)
          .accessibilityIdentifier("background.tasks")
          Text("Recent results · up to 20 retained on this screen")
            .font(AppFont.sans(10))
            .foregroundStyle(palette.foregroundMuted)
        } else {
          ForEach(Array(running.prefix(2))) { row in taskRow(row) }
          if running.count > 2 {
            Text("\(running.count - 2) more running · expand to view")
              .font(AppFont.sans(12))
              .foregroundStyle(palette.foregroundMuted)
          }
        }
      }
      .padding(12)
      .background(palette.card, in: RoundedRectangle(cornerRadius: 16))
      .padding(.horizontal, 12)
      .padding(.vertical, 5)
      .sheet(item: $selected) { task in
        // Keep only identity in presentation state; each poll supplies the current row.
        BackgroundWorkDetail(row: state.rows.first { $0.id == task.id }, isUnavailable: state.isUnavailable)
      }
    }
  }

  private func taskRow(_ row: BackgroundWorkItem) -> some View {
    Button { selected = SelectedTask(id: row.id) } label: {
      HStack(alignment: .top, spacing: 8) {
        Image(systemName: row.kind == .agent ? "person.crop.circle" : "terminal")
          .font(.system(size: 14))
          .foregroundStyle(palette.foregroundMuted)
          .frame(width: 18)
          .padding(.top, 2)
        Text(row.title)
          .font(AppFont.sans(12))
          .foregroundStyle(palette.foreground)
          .multilineTextAlignment(.leading)
          .lineLimit(expanded ? 3 : 2)
          .frame(maxWidth: .infinity, alignment: .leading)
        Label(row.status.label, systemImage: statusIcon(row.status))
          .font(AppFont.sans(11, .medium))
          .foregroundStyle(statusColor(row.status))
          .fixedSize(horizontal: false, vertical: true)
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel("\(row.title), \(state.isUnavailable ? "last checked: " : "")\(row.status.label)")
    .accessibilityIdentifier("background.row.\(row.id)")
    .accessibilityHint("Show task details")
  }

  private func statusIcon(_ status: BackgroundWorkStatus) -> String {
    switch status {
    case .running, .queued: "circle.dotted"
    case .completed: "checkmark.circle"
    case .failed: "exclamationmark.circle"
    case .stopped: "stop.circle"
    case .finished, .unknown: "minus.circle"
    }
  }

  private func statusColor(_ status: BackgroundWorkStatus) -> Color {
    switch status {
    case .failed: .red
    case .completed: .green
    case .running, .queued: palette.primaryText
    default: palette.foregroundMuted
    }
  }
}

private struct BackgroundWorkDetail: View {
  let row: BackgroundWorkItem?
  let isUnavailable: Bool
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 18) {
          if let row {
            Text(isUnavailable ? "Status unavailable" : row.status.label).font(.headline)
            if isUnavailable {
              Text("Last checked: \(row.status.label)").font(.subheadline).foregroundStyle(.secondary)
            }
            if let code = row.exitCode {
              Text("\(isUnavailable ? "Last checked exit code" : "Exit code"): \(code)").font(.subheadline)
            }
            Text(row.kind == .process ? "Command" : "Task").font(.caption).foregroundStyle(.secondary)
            Text(row.detail.isEmpty ? row.title : row.detail)
              .font(row.kind == .process ? .system(.body, design: .monospaced) : .body)
              .textSelection(.enabled)
              .frame(maxWidth: .infinity, alignment: .leading)
          } else {
            Text("This task is no longer in recent history.")
          }
        }
        .padding()
      }
      .navigationTitle("Background task")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
    }
  }
}
