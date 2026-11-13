import HermesKit
import SwiftUI

// The Agents area: one bot at a time as a hub of rows (its model, skills, chats, cron jobs,
// kanban, soul), like the Hermes mobile app's agent page. On iPhone a switcher over every bot sits
// on top; on iPad the bot list picks it and the hub fills the detail column.

/// The iPhone Agents area: the bot switcher, then the picked bot's hub.
struct AgentHubRoot: View {
  @Environment(AppModel.self) private var app
  @Environment(\.palette) private var palette

  var body: some View {
    let profile = app.currentHubProfile
    ScrollView {
      VStack(spacing: 24) {
        AgentSwitcher(selection: Binding(get: { profile }, set: { app.hubProfile = $0 }))
        AgentHub(profile: profile)
          .id(profile)
      }
      .padding(.top, 8)
      .padding(.bottom, 24)
      .frame(maxWidth: 680)
      .frame(maxWidth: .infinity)
    }
    .background(palette.screen.ignoresSafeArea())
    .refreshable {
      await app.refreshProfilesNow()
      await app.loadDefaultCatalog(profile, force: true)
    }
    .toolbarVisibility(.hidden, for: .navigationBar)
  }
}

/// One bot's hub as a page of its own (the iPad detail column).
struct AgentHubPage: View {
  let profile: String
  @Environment(AppModel.self) private var app
  @Environment(\.palette) private var palette

  var body: some View {
    ScrollView {
      VStack(spacing: 24) {
        VStack(spacing: 12) {
          AvatarView(profile: profile, size: 84)
          AgentTitle(profile: profile)
        }
        .padding(.top, 12)
        AgentHub(profile: profile)
      }
      .padding(.bottom, 24)
      .frame(maxWidth: 680)
      .frame(maxWidth: .infinity)
    }
    .background(palette.screen.ignoresSafeArea())
    .navigationTitle(app.title(forProfile: profile))
    .navigationBarTitleDisplayMode(.inline)
    .refreshable {
      await app.refreshProfilesNow()
      await app.loadDefaultCatalog(profile, force: true)
    }
  }
}

/// Every bot's picture in a row: the picked one large in the middle, its neighbours small beside
/// it. Swipe or tap to switch.
private struct AgentSwitcher: View {
  @Binding var selection: String
  @Environment(AppModel.self) private var app
  @State private var scrolled: String?
  @State private var width: CGFloat = 0
  private let tile: CGFloat = 96

  var body: some View {
    let profiles = app.orderedProfiles
    VStack(spacing: 10) {
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 2) {
          ForEach(profiles) { profile in
            let isOn = profile.name == selection
            Button {
              withAnimation(.snappy(duration: 0.3)) {
                selection = profile.name
                scrolled = profile.name
              }
            } label: {
              AvatarView(profile: profile.name, size: tile)
                .shadow(color: .black.opacity(isOn ? 0.12 : 0), radius: 12, y: 6)
                .scaleEffect(isOn ? 1 : 0.6)
                .opacity(isOn ? 1 : 0.8)
                .frame(width: tile, height: tile)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .id(profile.name)
            .accessibilityLabel(profile.title)
            .accessibilityAddTraits(isOn ? .isSelected : [])
            .accessibilityIdentifier("agent.switch")
          }
        }
        .scrollTargetLayout()
        // Room for the picked one's shadow, which the scroll view would clip.
        .padding(.vertical, 18)
      }
      .contentMargins(.horizontal, max((width - tile) / 2, 0), for: .scrollContent)
      .scrollTargetBehavior(.viewAligned)
      .scrollPosition(id: $scrolled, anchor: .center)
      .frame(height: tile + 36)
      .padding(.vertical, -12)
      .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
      .onAppear { scrolled = selection }
      .onChange(of: scrolled) { _, name in
        if let name, name != selection {
          UISelectionFeedbackGenerator().selectionChanged()
          withAnimation(.snappy(duration: 0.3)) { selection = name }
        }
      }
      .onChange(of: selection) { _, name in if scrolled != name { scrolled = name } }
      AgentTitle(profile: selection)
        .padding(.horizontal, 24)
    }
  }
}

/// The bot's name, and what it is for.
private struct AgentTitle: View {
  let profile: String
  @Environment(AppModel.self) private var app
  @Environment(\.palette) private var palette

  var body: some View {
    VStack(spacing: 4) {
      Text(app.title(forProfile: profile))
        .font(AppFont.sans(28, .bold))
        .foregroundStyle(palette.foreground)
        .accessibilityAddTraits(.isHeader)
      if let summary = app.profile(named: profile)?.summary, !summary.isEmpty {
        Text(summary)
          .font(AppFont.footnote)
          .foregroundStyle(palette.foregroundMuted)
          .multilineTextAlignment(.center)
          .lineLimit(2)
      }
    }
  }
}

/// The hub's actions and rows for one bot.
struct AgentHub: View {
  let profile: String
  @Environment(AppModel.self) private var app
  @Environment(\.palette) private var palette
  @State private var isOpeningBotChat = false
  @State private var isStartingChat = false

  var body: some View {
    let bot = app.profile(named: profile)
    VStack(alignment: .leading, spacing: 24) {
      actions
        .frame(maxWidth: .infinity)

      GroupedSection("") {
        row(.model(profile: profile)) {
          NavRow(
            title: "Model", symbol: "cpu",
            value: bot.map { $0.model.isEmpty ? "Not set" : ModelName($0.model).display } ?? "",
            detail: bot.map { app.providerName($0.provider) } ?? "")
        }
        .accessibilityIdentifier("hub.model")
        IconRowDivider()
        row(.skills(profile: profile)) {
          NavRow(title: "Skills", symbol: "cube", value: count(bot?.skillCount))
        }
        .accessibilityIdentifier("hub.skills")
      }

      GroupedSection("Work") {
        row(.chats(profile: profile)) {
          NavRow(title: "Chats", symbol: "bubble.left.and.bubble.right", value: count(app.agentTotals[profile]))
        }
        .accessibilityIdentifier("hub.chats")
        IconRowDivider()
        row(.cron(profile: profile)) {
          NavRow(title: "Cron", symbol: "clock", value: cronCount)
        }
        .accessibilityIdentifier("hub.cron")
        IconRowDivider()
        row(.kanban) {
          NavRow(title: "Kanban", symbol: "rectangle.split.3x1")
        }
        .accessibilityIdentifier("hub.kanban")
      }

      GroupedSection("Agent") {
        row(.soul(profile: profile)) {
          NavRow(title: "Soul", symbol: "sparkles")
        }
        .accessibilityIdentifier("hub.soul")
        IconRowDivider()
        row(.memory(profile: profile)) {
          NavRow(title: "Memory", symbol: "brain")
        }
        .accessibilityIdentifier("hub.memory")
      }
    }
    .padding(.horizontal, 16)
    .task(id: profile) { await app.loadDefaultCatalog(profile) }
    .task {
      if !app.areas.cron.hasLoaded { await app.areas.cron.refresh(app.client) }
    }
  }

  private func count(_ value: Int?) -> String {
    guard let value, value > 0 else { return "" }
    return value.formatted()
  }

  private var cronCount: String {
    guard app.areas.cron.hasLoaded else { return "" }
    return count(app.areas.cron.jobs.filter { $0.profile == profile }.count)
  }

  /// A row that opens a hub page. On iPad, Chats, Cron and Kanban have areas of their own and
  /// switch to them; everything else stacks in the detail column.
  @ViewBuilder
  private func row(_ route: HubRoute, @ViewBuilder label: () -> some View) -> some View {
    if app.usesSplitLayout, let action = splitAction(route) {
      Button(action: action, label: label).buttonStyle(RowButtonStyle())
    } else {
      NavigationLink(value: route, label: label).buttonStyle(RowButtonStyle())
    }
  }

  private func splitAction(_ route: HubRoute) -> (() -> Void)? {
    switch route {
    case .chats(let profile):
      return {
        app.tab = .chats
        app.showAgent(profile)
      }
    case .cron(let profile):
      return {
        app.areas.cronProfile = profile
        app.tab = .cron
      }
    case .kanban:
      return { app.tab = .kanban }
    default:
      return nil
    }
  }

  private var actions: some View {
    HStack(spacing: 10) {
      Button {
        Task { await openBotChat() }
      } label: {
        HStack(spacing: 6) {
          if isOpeningBotChat { ProgressView().controlSize(.small).tint(palette.prominentActionForeground) }
          Text("Bot Chat")
        }
        .font(AppFont.footnoteMedium)
        .foregroundStyle(palette.prominentActionForeground)
        .padding(.horizontal, 20)
        .frame(height: 40)
        .background(palette.prominentAction, in: Capsule())
      }
      .buttonStyle(.plain)
      .disabled(isOpeningBotChat)
      .accessibilityHint("Opens the one standing chat this bot keeps")

      Button {
        isStartingChat = true
        Task {
          await app.startChat(profile: profile)
          isStartingChat = false
        }
      } label: {
        HStack(spacing: 6) {
          if isStartingChat { ProgressView().controlSize(.small) }
          Text("New chat")
        }
        .font(AppFont.footnoteMedium)
        .foregroundStyle(palette.foreground)
        .padding(.horizontal, 20)
        .frame(height: 40)
        .glassEffect(.regular.interactive(), in: .capsule)
      }
      .buttonStyle(.plain)
      .disabled(isStartingChat)
      .accessibilityLabel("New chat with \(app.title(forProfile: profile))")
    }
  }

  private func openBotChat() async {
    guard let client = app.client else { return }
    isOpeningBotChat = true
    defer { isOpeningBotChat = false }
    do {
      try await client.rpc.waitUntilReady(timeout: 30)
      let found = try await client.botChat(profile: profile)
      if let live = found.created {
        app.openPrepared(live, profile: profile)
        app.scheduleReload(after: 0.6)
      } else {
        app.openChat(profile: profile, storedID: found.storedID)
      }
    } catch {
      app.show("Could not open Bot Chat: \(error.localizedDescription)", kind: .failure)
    }
  }
}

/// What a hub row opens.
struct HubDestination: View {
  let route: HubRoute
  @Environment(AppModel.self) private var app

  var body: some View {
    switch route {
    case .model(let profile): DefaultModelView(profile: profile)
    case .skills(let profile): SkillsView(profile: profile)
    case .soul(let profile): SoulView(profile: profile)
    case .memory(let profile): MemoryView(profile: profile)
    case .learning(let profile, let id, let title): LearningNodeView(profile: profile, id: id, title: title)
    case .cron(let profile): CronPage(profile: profile)
    case .chats(let profile): AgentSessionsView(profile: profile)
    case .kanban: KanbanPage()
    case .settings: SettingsView()
    case .chat(let profile, let storedID):
      ChatRouteView(profile: profile, storedID: storedID)
        .id(storedID)
    }
  }
}

/// The kanban board stacked over the hub, with its own card selection.
struct KanbanPage: View {
  @Environment(AppModel.self) private var app
  @State private var card: String?

  var body: some View {
    let model = app.areas.kanban
    KanbanBoardView(model: model, selection: $card)
      .navigationDestination(item: $card) { id in
        KanbanTaskView(model: model, taskID: id, select: { card = $0 })
      }
  }
}

/// One bot's cron jobs stacked over the hub.
struct CronPage: View {
  let profile: String
  @Environment(AppModel.self) private var app
  @State private var job: String?

  var body: some View {
    let model = app.areas.cron
    CronList(model: model, selection: $job, profile: profile)
      .navigationDestination(item: $job) { id in CronDetailView(model: model, jobID: id) }
  }
}

// MARK: - Pages

/// A bot's default model: the one new chats start on, its starred models, and every model.
struct DefaultModelView: View {
  let profile: String
  @Environment(AppModel.self) private var app
  @Environment(\.palette) private var palette
  @State private var showsAll = false
  @State private var isSwitching = false
  @State private var confirmation: (model: String, provider: String, message: String)?

  var body: some View {
    let choices = self.choices
    ScrollView {
      VStack(alignment: .leading, spacing: 24) {
        CurrentModelCard(
          model: choices.model, providerSlug: choices.currentProvider?.slug ?? choices.provider,
          providerName: choices.currentProvider?.name ?? app.providerName(choices.provider), placeholder: "Not set"
        ) { showsAll = true }
        FavouritesBlock(choices: choices, openAll: { showsAll = true }) { model, provider in
          choose(model, provider: provider, confirmed: false)
        }
        if let error = choices.error, choices.catalog == nil {
          Label("Could not load models: \(error)", systemImage: "exclamationmark.triangle")
            .font(AppFont.footnote)
            .foregroundStyle(palette.dangerForeground)
            .padding(.horizontal, 6)
        }
        Text("New chats with \(app.title(forProfile: profile)) start on this model. Chats already open keep theirs.")
          .font(AppFont.caption)
          .foregroundStyle(palette.foregroundMuted)
          .padding(.horizontal, 6)
      }
      .padding(.horizontal, 16)
      .padding(.top, 8)
      .padding(.bottom, 24)
      .frame(maxWidth: 680)
      .frame(maxWidth: .infinity)
    }
    .background(palette.screen.ignoresSafeArea())
    .navigationTitle("Default Model")
    .navigationBarTitleDisplayMode(.inline)
    .navigationDestination(isPresented: $showsAll) {
      AllModelsPage(title: "All models", choices: { self.choices }) { model, provider in
        choose(model, provider: provider, confirmed: false)
      }
    }
    .refreshable { await app.loadDefaultCatalog(profile, force: true) }
    .task { await app.loadDefaultCatalog(profile) }
    .task { await app.loadFavorites(force: true) }
    .alert("Expensive model", isPresented: Binding(get: { confirmation != nil }, set: { if !$0 { confirmation = nil } })) {
      Button("Cancel", role: .cancel) { confirmation = nil }
      Button("Use it") {
        if let pending = confirmation { choose(pending.model, provider: pending.provider, confirmed: true) }
        confirmation = nil
      }
    } message: {
      Text(confirmation?.message ?? "")
    }
  }

  private var choices: ModelChoices {
    let catalog = app.defaultCatalogs[profile]
    let bot = app.profile(named: profile)
    return ModelChoices(
      catalog: catalog?.providers, error: app.defaultCatalogErrors[profile],
      model: catalog?.model ?? bot?.model ?? "", provider: catalog?.provider ?? bot?.provider ?? "",
      isSwitching: isSwitching)
  }

  private func choose(_ model: String, provider: String, confirmed: Bool) {
    let current = choices
    if !confirmed, model == current.model, provider == (current.currentProvider?.slug ?? current.provider) {
      showsAll = false
      return
    }
    isSwitching = true
    Task {
      let prompt = await app.setDefaultModel(profile: profile, provider: provider, model: model, confirmed: confirmed)
      isSwitching = false
      if let prompt {
        confirmation = (model, provider, prompt)
      } else {
        showsAll = false
      }
    }
  }
}

/// A bot's installed skills by category.
struct SkillsView: View {
  let profile: String
  @Environment(AppModel.self) private var app
  @Environment(\.palette) private var palette
  @State private var query = ""
  @State private var error: String?

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 22) {
        if let categories = app.skillLists[profile] {
          let shown = filtered(categories)
          if shown.isEmpty {
            EmptyStateView(
              symbol: query.isEmpty ? "cube" : "magnifyingglass", title: query.isEmpty ? "No skills" : "No matches",
              text: query.isEmpty ? "Skills installed on your Mac show up here." : "Try a different search.")
          }
          ForEach(shown) { category in
            GroupedSection(category.title, trailing: "\(category.skills.count)") {
              ForEach(Array(category.skills.enumerated()), id: \.element) { offset, skill in
                if offset > 0 { IconRowDivider() }
                HStack(spacing: 14) {
                  RowSymbol(name: "cube")
                  Text(skill)
                    .font(AppFont.sans(16))
                    .foregroundStyle(palette.foreground)
                    .textSelection(.enabled)
                  Spacer(minLength: 0)
                }
                .padding(.horizontal, 18)
                .frame(minHeight: 50)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("skill.row")
              }
            }
          }
        } else if let error {
          EmptyStateView(symbol: "cube", title: "Can't load skills", text: error)
        } else {
          ProgressView().frame(maxWidth: .infinity).padding(.top, 60)
        }
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 12)
      .frame(maxWidth: 680)
      .frame(maxWidth: .infinity)
    }
    .background(palette.screen.ignoresSafeArea())
    .searchable(text: $query, prompt: "Search skills")
    .navigationTitle("Skills")
    .navigationBarTitleDisplayMode(.inline)
    .refreshable { await load(force: true) }
    .task { await load(force: false) }
  }

  private func filtered(_ categories: [SkillCategory]) -> [SkillCategory] {
    let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
    guard !needle.isEmpty else { return categories }
    return categories.compactMap { category in
      if category.title.lowercased().contains(needle) { return category }
      let skills = category.skills.filter { $0.lowercased().contains(needle) }
      return skills.isEmpty ? nil : SkillCategory(name: category.name, skills: skills)
    }
  }

  private func load(force: Bool) async {
    do {
      try await app.loadSkills(profile, force: force)
      error = nil
    } catch {
      self.error = error.localizedDescription
    }
  }
}

/// A bot's standing instructions.
struct SoulView: View {
  let profile: String
  @Environment(AppModel.self) private var app
  @Environment(\.palette) private var palette
  @State private var soul: String?
  @State private var error: String?

  var body: some View {
    ScrollView {
      Group {
        if let soul {
          if soul.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            EmptyStateView(symbol: "sparkles", title: "No soul yet", text: "This bot has no standing instructions.")
          } else {
            MarkdownView(text: soul, style: .note)
              .textSelection(.enabled)
              .padding(20)
              .frame(maxWidth: .infinity, alignment: .leading)
              .glassCard()
          }
        } else if let error {
          EmptyStateView(symbol: "sparkles", title: "Can't load the soul", text: error)
        } else {
          ProgressView().frame(maxWidth: .infinity).padding(.top, 60)
        }
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 12)
      .frame(maxWidth: 680)
      .frame(maxWidth: .infinity)
    }
    .background(palette.screen.ignoresSafeArea())
    .navigationTitle("Soul")
    .navigationBarTitleDisplayMode(.inline)
    .refreshable { await load() }
    .task { await load() }
  }

  private func load() async {
    guard let client = app.client else { return }
    do {
      soul = try await client.soul(profile: profile)
      error = nil
    } catch {
      self.error = error.localizedDescription
    }
  }
}
