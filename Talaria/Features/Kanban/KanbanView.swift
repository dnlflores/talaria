import HermesKit
import Observation
import SwiftUI

/// The kanban board on the Mac, one column at a time, kept fresh while the area is on screen.
@MainActor @Observable
final class KanbanModel {
  private(set) var boards: [KanbanBoardSummary] = []
  var boardSlug = ""
  private(set) var board: KanbanBoard?
  private(set) var hasLoaded = false
  private(set) var error: String?
  var column = ""
  private(set) var details: [String: KanbanTaskDetail] = [:]

  /// The columns worth a segment: those with cards, plus the one on screen.
  var segments: [KanbanColumn] {
    (board?.columns ?? []).filter { !$0.tasks.isEmpty || $0.name == column }
  }

  var currentColumn: KanbanColumn? { board?.columns.first { $0.name == column } }

  func refresh(_ client: HermesClient?) async {
    guard let client else { return }
    do {
      if boards.isEmpty {
        let listed = try await client.kanbanBoards()
        boards = listed.boards
        if boardSlug.isEmpty { boardSlug = listed.current }
      }
      let fresh = try await client.kanbanBoard(slug: boardSlug)
      if fresh != board { board = fresh }
      if column.isEmpty || !(fresh.columns.contains { $0.name == column }) { column = KanbanModel.firstColumn(in: fresh) }
      error = nil
    } catch {
      self.error = error.localizedDescription
    }
    hasLoaded = true
  }

  func switchBoard(to slug: String, client: HermesClient?) async {
    boardSlug = slug
    board = nil
    column = ""
    hasLoaded = false
    await refresh(client)
  }

  func loadDetail(_ id: String, client: HermesClient?) async throws {
    guard let client else { return }
    details[id] = try await client.kanbanTask(id: id, board: boardSlug)
  }

  func task(_ id: String) -> KanbanTask? {
    for column in board?.columns ?? [] {
      if let task = column.tasks.first(where: { $0.id == id }) { return task }
    }
    return details[id]?.task
  }

  /// The column that most likely needs a look: work in progress and blocked cards first.
  static func firstColumn(in board: KanbanBoard) -> String {
    let priority = ["running", "blocked", "review", "ready", "todo", "triage", "scheduled", "done"]
    for name in priority where board.columns.contains(where: { $0.name == name && !$0.tasks.isEmpty }) { return name }
    return board.columns.first { !$0.tasks.isEmpty }?.name ?? board.columns.first?.name ?? ""
  }
}

struct KanbanBoardView: View {
  @Bindable var model: KanbanModel
  @Binding var selection: String?
  @Environment(AppModel.self) private var app
  @Environment(\.palette) private var palette

  var body: some View {
    List {
      if model.board != nil, !model.segments.isEmpty {
        columnPicker
          .listRowInsets(EdgeInsets(top: 4, leading: Metrics.screenPadding, bottom: 10, trailing: Metrics.screenPadding))
          .listRowSeparator(.hidden)
          .listRowBackground(Color.clear)
      }
      if !model.hasLoaded {
        ForEach(0..<5, id: \.self) { _ in
          RowPlaceholder()
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
            .listRowSeparatorTint(palette.border)
        }
      } else if let error = model.error, model.board == nil {
        EmptyStateView(symbol: "rectangle.split.3x1", title: "Can't load the board", text: error)
          .listRowSeparator(.hidden)
          .listRowBackground(Color.clear)
      } else if let column = model.currentColumn {
        if column.tasks.isEmpty {
          EmptyStateView(symbol: "tray", title: "Nothing in \(column.label)", text: "Cards land here as work moves along.")
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
        } else {
          ForEach(column.tasks.sorted { $0.recency > $1.recency }) { task in
            let isSelected = app.usesSplitLayout && selection == task.id
            Button {
              selection = task.id
            } label: {
              KanbanCardRow(task: task)
            }
            .buttonStyle(RowButtonStyle())
            .listRowInsets(EdgeInsets())
            .listRowBackground(isSelected ? palette.threadSelected : Color.clear)
            .listRowSeparator(.hidden, edges: .top)
            .listRowSeparatorTint(palette.border)
            .alignmentGuide(.listRowSeparatorLeading) { _ in Metrics.screenPadding }
            .accessibilityIdentifier("kanban.card")
          }
        }
      }
    }
    .listStyle(.plain)
    .scrollContentBackground(.hidden)
    .background(palette.screen.ignoresSafeArea())
    .environment(\.defaultMinListRowHeight, 10)
    .navigationTitle(boardTitle)
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) { columnsMenu }
    }
    .refreshable { await model.refresh(app.client) }
    .task {
      // Workers move cards on their own: look again while the board is on screen.
      while !Task.isCancelled {
        await model.refresh(app.client)
        try? await Task.sleep(for: .seconds(10))
      }
    }
  }

  private var boardTitle: String {
    if model.boards.count > 1, let board = model.boards.first(where: { $0.slug == model.boardSlug }) { return board.name }
    return "Kanban"
  }

  /// One segment per column that has cards. A board with many busy columns falls back to a menu.
  @ViewBuilder
  private var columnPicker: some View {
    let segments = model.segments
    if segments.count <= 4 {
      Picker("Column", selection: $model.column) {
        ForEach(segments) { column in
          Text("\(column.label) \(column.tasks.count)").tag(column.name)
        }
      }
      .pickerStyle(.segmented)
      .accessibilityIdentifier("kanban.columns")
    } else {
      HStack {
        Text("\(model.currentColumn?.label ?? "") · \(model.currentColumn?.tasks.count ?? 0)")
          .font(AppFont.bodySemibold)
          .foregroundStyle(palette.foreground)
        Spacer()
        Text("\(segments.count) columns with cards")
          .font(AppFont.caption)
          .foregroundStyle(palette.foregroundMuted)
      }
    }
  }

  private var columnsMenu: some View {
    Menu {
      Picker("Column", selection: $model.column) {
        ForEach(model.board?.columns ?? []) { column in
          Text("\(column.label) (\(column.tasks.count))").tag(column.name)
        }
      }
      .pickerStyle(.inline)
      if model.boards.count > 1 {
        Section("Board") {
          ForEach(model.boards) { board in
            Button {
              Task { await model.switchBoard(to: board.slug, client: app.client) }
            } label: {
              Label(board.name, systemImage: board.slug == model.boardSlug ? "checkmark" : "rectangle.split.3x1")
            }
          }
        }
      }
    } label: {
      Image(systemName: "line.3.horizontal.decrease")
    }
    .accessibilityLabel("Columns")
  }
}

/// A card as a three-line row: who has it and its state, its title, and its id and activity.
private struct KanbanCardRow: View {
  let task: KanbanTask
  @Environment(AppModel.self) private var app
  @Environment(\.palette) private var palette

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: 6) {
        if !task.assignee.isEmpty {
          AvatarView(profile: task.assignee, size: 16)
          Text(app.title(forProfile: task.assignee))
            .font(AppFont.label)
            .foregroundStyle(palette.foregroundSecondary)
            .lineLimit(1)
        } else {
          Text("Unassigned").font(AppFont.label).foregroundStyle(palette.foregroundMuted)
        }
        if task.priority > 0 {
          Text("P\(task.priority)").font(AppFont.mono(11)).foregroundStyle(palette.warningForeground)
        }
        Spacer(minLength: 8)
        KanbanStatus(task: task)
      }
      Text(task.title)
        .font(AppFont.body)
        .foregroundStyle(palette.foreground)
        .lineLimit(2)
        .fixedSize(horizontal: false, vertical: true)
      HStack(spacing: 6) {
        Text(meta)
          .font(AppFont.mono(12))
          .foregroundStyle(palette.foregroundMuted)
          .lineLimit(1)
          .truncationMode(.middle)
        Spacer(minLength: 8)
        if task.warningCount > 0 {
          Image(systemName: "exclamationmark.triangle")
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(palette.warningForeground)
            .accessibilityLabel("\(task.warningCount) warnings")
        }
      }
    }
    .padding(.horizontal, Metrics.screenPadding)
    .padding(.vertical, 12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .contentShape(Rectangle())
    .accessibilityElement(children: .combine)
  }

  private var meta: String {
    var parts = [task.id]
    if task.recency > 0 { parts.append(Format.ago(task.recency)) }
    if task.commentCount > 0 { parts.append(task.commentCount == 1 ? "1 comment" : "\(task.commentCount) comments") }
    if let done = task.progressDone, let total = task.progressTotal { parts.append("\(done)/\(total) done") }
    return parts.joined(separator: " · ")
  }
}

/// The state of a card in words.
struct KanbanStatus: View {
  let task: KanbanTask
  @Environment(\.palette) private var palette

  var body: some View {
    switch task.status {
    case "running":
      HStack(spacing: 5) {
        WorkingDots()
        Text("Running").font(AppFont.labelMedium).foregroundStyle(palette.primaryText)
      }
    case "blocked":
      Text(KanbanStatus.blockWords(task.blockKind)).font(AppFont.labelMedium).foregroundStyle(palette.warningForeground)
    case "review":
      Text("In review").font(AppFont.label).foregroundStyle(palette.primaryText)
    case "done":
      Text("Done").font(AppFont.label).foregroundStyle(palette.foregroundMuted)
    default:
      Text(KanbanColumn.label(for: task.status)).font(AppFont.label).foregroundStyle(palette.foregroundMuted)
    }
  }

  static func blockWords(_ kind: String) -> String {
    switch kind {
    case "needs_input": return "Needs you"
    case "dependency": return "Waiting on a card"
    case "capability": return "Missing a capability"
    case "transient": return "Retrying"
    default: return "Blocked"
    }
  }
}

struct KanbanTaskView: View {
  let model: KanbanModel
  let taskID: String
  let select: (String) -> Void
  @Environment(AppModel.self) private var app
  @Environment(\.palette) private var palette
  @State private var error: String?
  @State private var showsWholeBrief = false

  var body: some View {
    Group {
      if let task = model.details[taskID]?.task ?? model.task(taskID) {
        content(task, detail: model.details[taskID])
      } else if let error {
        EmptyStateView(symbol: "rectangle.split.3x1", title: "Can't open this card", text: error)
      } else {
        ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
    .background(palette.screen.ignoresSafeArea())
    .navigationBarTitleDisplayMode(.inline)
    .task(id: "\(taskID)|\(model.board?.latestEventID ?? 0)") { await load() }
  }

  private func load() async {
    do {
      try await model.loadDetail(taskID, client: app.client)
      error = nil
    } catch {
      self.error = error.localizedDescription
    }
  }

  private func content(_ task: KanbanTask, detail: KanbanTaskDetail?) -> some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 26) {
        VStack(alignment: .leading, spacing: 8) {
          HStack(spacing: 6) {
            if !task.assignee.isEmpty {
              AvatarView(profile: task.assignee, size: 16)
              Text(app.title(forProfile: task.assignee)).font(AppFont.label).foregroundStyle(palette.foregroundSecondary)
            }
            Spacer(minLength: 8)
            KanbanStatus(task: task)
          }
          Text(task.title)
            .font(AppFont.title)
            .foregroundStyle(palette.foreground)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
          Text(task.id).font(AppFont.mono(12)).foregroundStyle(palette.foregroundMuted)
        }
        .padding(.horizontal, 4)

        if task.status == "blocked" || !task.lastFailureError.isEmpty {
          notice(task)
        }

        if !task.latestSummary.isEmpty {
          GroupedSection("Latest") {
            MarkdownView(text: task.latestSummary, style: .note)
              .textSelection(.enabled)
              .padding(16)
          }
        }

        if !task.body.isEmpty {
          GroupedSection("Brief") {
            VStack(alignment: .leading, spacing: 10) {
              MarkdownView(text: brief(task.body), style: .note).textSelection(.enabled)
              if isLong(task.body) {
                Button(showsWholeBrief ? "Show less" : "Show all") {
                  withAnimation(.snappy(duration: 0.25)) { showsWholeBrief.toggle() }
                }
                .font(AppFont.labelMedium)
                .foregroundStyle(palette.primaryText)
              }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
          }
        }

        GroupedSection("Details") {
          ValueRow("Column", KanbanColumn.label(for: task.status))
          if !task.workspacePath.isEmpty {
            GroupDivider()
            ValueRow("Folder", Format.folder(task.workspacePath), mono: true)
          }
          if !task.branchName.isEmpty {
            GroupDivider()
            ValueRow("Branch", task.branchName, mono: true)
          }
          if !task.modelOverride.isEmpty {
            GroupDivider()
            ValueRow("Model", Format.shortModel(task.modelOverride), mono: true)
          }
          if task.createdAt > 0 {
            GroupDivider()
            ValueRow("Created", Format.agoPhrase(task.createdAt).capitalizedFirst)
          }
          if task.completedAt > 0 {
            GroupDivider()
            ValueRow("Finished", Format.agoPhrase(task.completedAt).capitalizedFirst)
          }
        }

        if let detail {
          links(detail)
          runs(detail, task: task)
          comments(detail)
        }
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 16)
      .frame(maxWidth: 680, alignment: .leading)
      .frame(maxWidth: .infinity)
    }
    .refreshable { await load() }
  }

  private func notice(_ task: KanbanTask) -> some View {
    let text: String
    if task.status == "blocked" {
      switch task.blockKind {
      case "needs_input": text = "This card is waiting for your input. Answer in its comments on your Mac."
      case "dependency": text = "This card is waiting for another card to finish."
      case "capability": text = "The worker is missing a tool or permission it needs."
      case "transient": text = "The last run hit a temporary error. It will try again."
      default: text = "This card is blocked."
      }
    } else {
      text = task.lastFailureError
    }
    return Label(text, systemImage: "exclamationmark.triangle")
      .font(AppFont.label)
      .foregroundStyle(palette.warningForeground)
      .lineLimit(8)
      .padding(.horizontal, 12)
      .padding(.vertical, 10)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(palette.warning, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
      .overlay { RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(palette.warningBorder, lineWidth: 1) }
  }

  @ViewBuilder
  private func links(_ detail: KanbanTaskDetail) -> some View {
    let all = detail.parents.map { ("Depends on", $0) } + detail.children.map { ("Leads to", $0) }
    if !all.isEmpty {
      GroupedSection("Linked cards") {
        ForEach(Array(all.enumerated()), id: \.offset) { offset, entry in
          if offset > 0 { GroupDivider() }
          Button {
            select(entry.1.id)
          } label: {
            HStack(spacing: 8) {
              VStack(alignment: .leading, spacing: 2) {
                Text(entry.0).font(AppFont.caption).foregroundStyle(palette.foregroundMuted)
                Text(entry.1.title).font(AppFont.body).foregroundStyle(palette.foreground).lineLimit(2)
              }
              Spacer(minLength: 8)
              if !entry.1.status.isEmpty {
                Text(KanbanColumn.label(for: entry.1.status)).font(AppFont.label).foregroundStyle(palette.foregroundMuted)
              }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
            .contentShape(Rectangle())
          }
          .buttonStyle(RowButtonStyle())
        }
      }
    }
  }

  @ViewBuilder
  private func runs(_ detail: KanbanTaskDetail, task: KanbanTask) -> some View {
    if !detail.runs.isEmpty {
      GroupedSection("Runs", trailing: detail.runs.count > 8 ? "\(detail.runs.count) in all" : "") {
        ForEach(Array(detail.runs.suffix(8).reversed().enumerated()), id: \.element.id) { offset, run in
          if offset > 0 { GroupDivider() }
          let row = runRow(run)
          if !run.sessionID.isEmpty {
            Button {
              app.openChat(profile: run.profile.isEmpty ? task.assignee : run.profile, storedID: run.sessionID)
            } label: {
              row
            }
            .buttonStyle(RowButtonStyle())
          } else {
            row
          }
        }
      }
    }
  }

  private func runRow(_ run: KanbanRun) -> some View {
    HStack(alignment: .top, spacing: 8) {
      VStack(alignment: .leading, spacing: 3) {
        HStack(spacing: 6) {
          if !run.profile.isEmpty { AvatarView(profile: run.profile, size: 14) }
          Text((run.outcome.isEmpty ? run.status : run.outcome).replacingOccurrences(of: "_", with: " ").capitalizedFirst)
            .font(AppFont.labelMedium)
            .foregroundStyle(run.error.isEmpty ? palette.foregroundSecondary : palette.dangerForeground)
          if run.startedAt > 0 {
            Text(Format.ago(run.startedAt)).font(AppFont.caption).foregroundStyle(palette.foregroundMuted)
          }
          if run.endedAt > run.startedAt, run.startedAt > 0 {
            Text(WorkLog.duration(run.endedAt - run.startedAt)).font(AppFont.mono(11)).foregroundStyle(palette.foregroundMuted)
          }
        }
        let text = run.error.isEmpty ? run.summary : run.error
        if !text.isEmpty {
          Text(text).font(AppFont.footnote).foregroundStyle(palette.foregroundMuted).lineLimit(3)
        }
      }
      Spacer(minLength: 8)
      if !run.sessionID.isEmpty {
        Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(palette.chevron)
      }
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 11)
    .contentShape(Rectangle())
    .accessibilityElement(children: .combine)
  }

  @ViewBuilder
  private func comments(_ detail: KanbanTaskDetail) -> some View {
    if !detail.comments.isEmpty {
      GroupedSection("Comments", trailing: detail.comments.count > 10 ? "Latest 10 of \(detail.comments.count)" : "") {
        ForEach(Array(detail.comments.suffix(10).enumerated()), id: \.element.id) { offset, comment in
          if offset > 0 { GroupDivider() }
          VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
              if app.profile(named: comment.author) != nil { AvatarView(profile: comment.author, size: 14) }
              Text(app.profile(named: comment.author) != nil ? app.title(forProfile: comment.author) : comment.author.capitalizedFirst)
                .font(AppFont.labelMedium)
                .foregroundStyle(palette.foregroundSecondary)
              Text(Format.ago(comment.createdAt)).font(AppFont.caption).foregroundStyle(palette.foregroundMuted)
            }
            MarkdownView(text: comment.body, style: .note).textSelection(.enabled)
          }
          .padding(.horizontal, 16)
          .padding(.vertical, 12)
        }
      }
    }
  }

  private func isLong(_ text: String) -> Bool { text.count > 1200 }

  private func brief(_ text: String) -> String {
    guard isLong(text), !showsWholeBrief else { return text }
    return String(text.prefix(1200)) + "…"
  }
}

extension String {
  /// "just now" → "Just now", leaving the rest alone.
  var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
