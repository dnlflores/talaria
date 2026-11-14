import HermesKit
import Observation
import SwiftUI

/// Cron jobs on the Mac, kept fresh while the area is on screen.
@MainActor @Observable
final class CronModel {
  private(set) var jobs: [CronJob] = []
  private(set) var hasLoaded = false
  private(set) var error: String?
  private(set) var busy: Set<String> = []
  private(set) var runs: [String: [CronRun]] = [:]

  func refresh(_ client: HermesClient?) async {
    guard let client else { return }
    do {
      let fresh = try await client.cronJobs()
      if fresh != jobs { jobs = fresh }
      error = nil
    } catch {
      self.error = error.localizedDescription
    }
    hasLoaded = true
  }

  func loadRuns(_ job: CronJob, client: HermesClient?) async {
    guard let client, let list = try? await client.cronRuns(jobID: job.id, profile: job.profile, limit: 15) else { return }
    runs[job.id] = list
  }

  func job(_ id: String) -> CronJob? { jobs.first { $0.id == id } }

  /// Pause, resume or run now. Returns a message for a toast.
  func perform(_ action: Action, on job: CronJob, client: HermesClient?) async -> (String, ToastMessage.Kind) {
    guard let client else { return ("Not connected to your Mac.", .failure) }
    busy.insert(job.id)
    defer { busy.remove(job.id) }
    do {
      switch action {
      case .pause: try await client.pauseCron(jobID: job.id, profile: job.profile)
      case .resume: try await client.resumeCron(jobID: job.id, profile: job.profile)
      case .runNow: try await client.triggerCron(jobID: job.id, profile: job.profile)
      }
      await refresh(client)
      switch action {
      case .pause: return ("Paused \(job.title).", .success)
      case .resume: return ("\(job.title) is back on its schedule.", .success)
      case .runNow: return ("\(job.title) is running now.", .success)
      }
    } catch {
      return ("Could not \(action.verb) \(job.title): \(error.localizedDescription)", .failure)
    }
  }

  enum Action {
    case pause, resume, runNow

    var verb: String {
      switch self {
      case .pause: return "pause"
      case .resume: return "resume"
      case .runNow: return "run"
      }
    }
  }
}

struct CronList: View {
  let model: CronModel
  @Binding var selection: String?
  /// Only this bot's jobs (opened from its hub). Nil: every bot's.
  var profile: String?
  @Environment(AppModel.self) private var app
  @Environment(\.palette) private var palette

  var body: some View {
    List {
      if !model.hasLoaded {
        ForEach(0..<5, id: \.self) { _ in
          RowPlaceholder()
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
            .listRowSeparatorTint(palette.border)
        }
      } else if ordered.isEmpty {
        EmptyStateView(
          symbol: "clock", title: model.error == nil ? "No cron jobs" : "Can't load cron jobs",
          text: model.error ?? (profile.map { "Jobs \(app.title(forProfile: $0)) runs on a schedule show up here." }
            ?? "Jobs you schedule on your Mac show up here."))
          .listRowSeparator(.hidden)
          .listRowBackground(Color.clear)
      } else {
        ForEach(ordered) { job in
          let isSelected = app.usesSplitLayout && selection == job.id
          Button {
            selection = job.id
          } label: {
            CronRow(job: job)
          }
          .buttonStyle(RowButtonStyle())
          .listRowInsets(EdgeInsets())
          .listRowBackground(isSelected ? palette.threadSelected : Color.clear)
          .listRowSeparator(.hidden, edges: .top)
          .listRowSeparatorTint(palette.border)
          .alignmentGuide(.listRowSeparatorLeading) { _ in Metrics.screenPadding }
          .accessibilityIdentifier("cron.row")
          .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button {
              Task {
                let (text, kind) = await model.perform(job.isPaused ? .resume : .pause, on: job, client: app.client)
                app.show(text, kind: kind)
              }
            } label: {
              Label(job.isPaused ? "Resume" : "Pause", systemImage: job.isPaused ? "play" : "pause")
            }
            .tint(palette.primary)
          }
        }
      }
    }
    .listStyle(.plain)
    .scrollContentBackground(.hidden)
    .screenBackground()
    .environment(\.defaultMinListRowHeight, 10)
    .navigationTitle(profile.map { "\(app.title(forProfile: $0)) · Cron" } ?? "Cron")
    .navigationBarTitleDisplayMode(.inline)
    .refreshable { await model.refresh(app.client) }
    .task {
      // Jobs change state on their own (a run starts, a run fails): look again while on screen.
      while !Task.isCancelled {
        await model.refresh(app.client)
        try? await Task.sleep(for: .seconds(20))
      }
    }
  }

  /// Running and failing jobs first, then by the next run.
  private var ordered: [CronJob] {
    model.jobs.filter { profile == nil || $0.profile == profile }.sorted { a, b in
      func rank(_ job: CronJob) -> Int {
        if job.isRunning { return 0 }
        if job.lastRunFailed && !job.isPaused { return 1 }
        if job.isPaused || job.isCompleted { return 3 }
        return 2
      }
      if rank(a) != rank(b) { return rank(a) < rank(b) }
      return (a.nextRunAt ?? .distantFuture) < (b.nextRunAt ?? .distantFuture)
    }
  }
}

/// A job as a three-line row: bot and state, name, schedule and last run.
private struct CronRow: View {
  let job: CronJob
  @Environment(AppModel.self) private var app
  @Environment(\.palette) private var palette

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: 6) {
        AvatarView(profile: job.profile, size: 16)
        Text(app.title(forProfile: job.profile))
          .font(AppFont.label)
          .foregroundStyle(palette.foregroundSecondary)
          .lineLimit(1)
        Spacer(minLength: 8)
        CronStatus(job: job)
      }
      Text(job.title)
        .font(AppFont.body)
        .foregroundStyle(palette.foreground)
        .lineLimit(1)
      HStack(spacing: 6) {
        Text(meta)
          .font(AppFont.mono(12))
          .foregroundStyle(palette.foregroundMuted)
          .lineLimit(1)
          .truncationMode(.middle)
        Spacer(minLength: 8)
        Image(systemName: job.isScript ? "apple.terminal" : "clock")
          .font(.system(size: 11, weight: .medium))
          .foregroundStyle(palette.iconMuted)
      }
    }
    .padding(.horizontal, Metrics.screenPadding)
    .padding(.vertical, 12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .contentShape(Rectangle())
    .accessibilityElement(children: .combine)
  }

  private var meta: String {
    var parts = [job.scheduleDisplay.isEmpty ? job.schedule : job.scheduleDisplay]
    if let last = job.lastRunAt { parts.append("ran \(Format.agoPhrase(last.timeIntervalSince1970))") }
    if job.isScript { parts.append("script") }
    return parts.filter { !$0.isEmpty }.joined(separator: " · ")
  }
}

/// The state of a job in one or two words.
private struct CronStatus: View {
  let job: CronJob
  @Environment(\.palette) private var palette

  var body: some View {
    if job.isRunning {
      HStack(spacing: 5) {
        WorkingDots()
        Text("Running").font(AppFont.labelMedium).foregroundStyle(palette.primaryText)
      }
    } else if job.isPaused {
      Text("Paused").font(AppFont.label).foregroundStyle(palette.warningForeground)
    } else if job.isCompleted {
      Text("Done").font(AppFont.label).foregroundStyle(palette.foregroundMuted)
    } else if job.lastRunFailed {
      Text("Failed").font(AppFont.labelMedium).foregroundStyle(palette.dangerForeground)
    } else if let next = job.nextRunAt, next <= Date() {
      // The scheduler picks a due job up within a few seconds.
      Text("Due").font(AppFont.label).foregroundStyle(palette.foregroundMuted)
    } else {
      Text(Format.relative(job.nextRunAt)).font(AppFont.label).foregroundStyle(palette.foregroundMuted)
    }
  }
}

struct CronDetailView: View {
  let model: CronModel
  let jobID: String
  @Environment(AppModel.self) private var app
  @Environment(\.palette) private var palette
  @State private var confirmsRun = false

  var body: some View {
    Group {
      if let job = model.job(jobID) {
        content(job)
      } else {
        EmptyStateView(symbol: "clock", title: "Job not found", text: "It may have been deleted on your Mac.")
      }
    }
    .screenBackground()
    .navigationBarTitleDisplayMode(.inline)
  }

  private func content(_ job: CronJob) -> some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 26) {
        VStack(alignment: .leading, spacing: 8) {
          HStack(spacing: 6) {
            AvatarView(profile: job.profile, size: 16)
            Text(app.title(forProfile: job.profile))
              .font(AppFont.label)
              .foregroundStyle(palette.foregroundSecondary)
            Spacer(minLength: 8)
            CronStatus(job: job)
          }
          Text(job.title)
            .font(AppFont.title)
            .foregroundStyle(palette.foreground)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 4)

        actions(job)

        if !job.lastError.isEmpty || !job.lastDeliveryError.isEmpty {
          Label(job.lastError.isEmpty ? "Delivery failed: \(job.lastDeliveryError)" : job.lastError, systemImage: "exclamationmark.triangle")
            .font(AppFont.label)
            .foregroundStyle(palette.warningForeground)
            .lineLimit(6)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(palette.warning, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(palette.warningBorder, lineWidth: 1) }
        }

        GroupedSection("Schedule") {
          ValueRow("Schedule", job.scheduleDisplay.isEmpty ? job.schedule : job.scheduleDisplay, mono: true)
          GroupDivider()
          ValueRow("Next run", job.isPaused ? "Paused" : when(job.nextRunAt))
          GroupDivider()
          ValueRow("Last run", lastRun(job), color: job.lastRunFailed ? palette.dangerForeground : nil)
          GroupDivider()
          ValueRow("Runs", runs(job))
          if !job.deliver.isEmpty {
            GroupDivider()
            ValueRow("Sends results to", job.deliver.capitalized)
          }
          if !job.model.isEmpty {
            GroupDivider()
            ValueRow("Model", Format.shortModel(job.model), mono: true)
          }
        }

        GroupedSection(job.isScript ? "Script" : "Prompt") {
          Group {
            if job.isScript {
              VStack(alignment: .leading, spacing: 8) {
                Text(job.script).font(AppFont.mono(13)).foregroundStyle(palette.foreground)
                if !job.prompt.isEmpty {
                  Text(job.prompt).font(AppFont.footnote).foregroundStyle(palette.foregroundSecondary)
                }
              }
            } else {
              MarkdownView(text: job.prompt, style: .note).textSelection(.enabled)
            }
          }
          .padding(16)
          .frame(maxWidth: .infinity, alignment: .leading)
        }

        recentRuns(job)
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 16)
      .frame(maxWidth: 680, alignment: .leading)
      .frame(maxWidth: .infinity)
    }
    .refreshable {
      await model.refresh(app.client)
      await model.loadRuns(job, client: app.client)
    }
    .task(id: job.lastRunAt) { await model.loadRuns(job, client: app.client) }
    .confirmationDialog("Run \(job.title) now?", isPresented: $confirmsRun, titleVisibility: .visible) {
      Button("Run now") {
        Task {
          let (text, kind) = await model.perform(.runNow, on: job, client: app.client)
          app.show(text, kind: kind)
        }
      }
    } message: {
      Text(job.isScript ? "It runs once outside its schedule." : "It runs once outside its schedule and uses model calls.")
    }
  }

  private func actions(_ job: CronJob) -> some View {
    let isBusy = model.busy.contains(job.id)
    return HStack(spacing: 10) {
      Button {
        Task {
          let (text, kind) = await model.perform(job.isPaused ? .resume : .pause, on: job, client: app.client)
          app.show(text, kind: kind)
        }
      } label: {
        Label(job.isPaused ? "Resume" : "Pause", systemImage: job.isPaused ? "play.fill" : "pause.fill")
          .font(AppFont.footnoteMedium)
          .foregroundStyle(palette.prominentActionForeground)
          .padding(.horizontal, 18)
          .frame(height: 38)
          .background(palette.prominentAction, in: Capsule())
      }
      .buttonStyle(.plain)
      .accessibilityIdentifier("cron.toggle")

      Button {
        confirmsRun = true
      } label: {
        Label("Run now", systemImage: "bolt")
          .font(AppFont.footnoteMedium)
          .foregroundStyle(palette.foregroundSecondary)
          .padding(.horizontal, 18)
          .frame(height: 38)
          .background(palette.secondary, in: Capsule())
          .overlay { Capsule().strokeBorder(palette.secondaryBorder, lineWidth: 1) }
      }
      .buttonStyle(.plain)
      .disabled(job.isRunning)

      if isBusy { ProgressView().controlSize(.small) }
    }
    .disabled(isBusy)
    .padding(.horizontal, 4)
  }

  @ViewBuilder
  private func recentRuns(_ job: CronJob) -> some View {
    if let runs = model.runs[job.id], !runs.isEmpty {
      GroupedSection("Recent runs") {
        ForEach(Array(runs.prefix(10).enumerated()), id: \.element.id) { offset, run in
          if offset > 0 { GroupDivider() }
          if run.isChat {
            Button {
              app.openChat(profile: job.profile, storedID: run.id)
            } label: {
              runRow(run, tappable: true)
            }
            .buttonStyle(RowButtonStyle())
          } else {
            runRow(run, tappable: false)
          }
        }
      }
    }
  }

  private func runRow(_ run: CronRun, tappable: Bool) -> some View {
    HStack(alignment: .top, spacing: 8) {
      VStack(alignment: .leading, spacing: 3) {
        HStack(spacing: 6) {
          Text(run.outcome.isEmpty ? "Run" : run.outcome)
            .font(AppFont.labelMedium)
            .foregroundStyle(run.outcome.lowercased().contains("fail") ? palette.dangerForeground : palette.foregroundSecondary)
          Text(Format.ago(run.startedAt)).font(AppFont.caption).foregroundStyle(palette.foregroundMuted)
          if run.endedAt > run.startedAt {
            Text(WorkLog.duration(run.endedAt - run.startedAt)).font(AppFont.mono(11)).foregroundStyle(palette.foregroundMuted)
          }
        }
        let summary = cleaned(run.preview)
        if !summary.isEmpty {
          Text(summary)
            .font(AppFont.footnote)
            .foregroundStyle(palette.foregroundMuted)
            .lineLimit(2)
        }
      }
      Spacer(minLength: 8)
      if tappable {
        Image(systemName: "chevron.right")
          .font(.system(size: 12, weight: .semibold))
          .foregroundStyle(palette.chevron)
      }
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 11)
    .contentShape(Rectangle())
    .accessibilityElement(children: .combine)
  }

  /// The run preview is the start of a Markdown report; drop its heading marks for one or two lines.
  private func cleaned(_ text: String) -> String {
    text.replacing(/[#*`]+/, with: "").replacing(/\s+/, with: " ").trimmingCharacters(in: .whitespaces)
  }

  private func when(_ date: Date?) -> String {
    guard let date else { return "Not scheduled" }
    let relative = date <= Date() ? "Due" : Format.relative(date)
    return "\(relative) · \(Format.clock(date.timeIntervalSince1970))"
  }

  private func lastRun(_ job: CronJob) -> String {
    guard let last = job.lastRunAt else { return "Never" }
    let status = job.lastStatus.isEmpty ? "" : " · \(job.lastStatus == "ok" ? "OK" : job.lastStatus.capitalized)"
    return Format.agoPhrase(last.timeIntervalSince1970).capitalizedFirst + status
  }

  private func runs(_ job: CronJob) -> String {
    let done = job.completedRuns.formatted()
    if let times = job.repeatTimes { return "\(done) of \(times.formatted())" }
    return done
  }
}
