import SwiftUI

@main
struct TalariaApp: App {
  @State private var app = AppModel()
  @Environment(\.scenePhase) private var scenePhase

  var body: some Scene {
    WindowGroup {
      ThemedRoot(family: app.preferences.themeFamily, appearance: app.preferences.appearance) {
        RootView()
      }
      .environment(app)
      .task { await app.launch() }
      .onChange(of: scenePhase) { _, phase in
        if phase == .active { app.becameActive() }
        if phase == .background { app.wentToBackground() }
      }
    }
  }
}

/// Chooses between the connect flow and the app, and hosts what floats above both.
struct RootView: View {
  @Environment(AppModel.self) private var app
  @Environment(\.palette) private var palette

  var body: some View {
    @Bindable var app = app
    ZStack {
      switch app.phase {
      case .launching:
        Wordmark(size: 30)
      case .needsServer, .needsPassword:
        ConnectView()
          .transition(.opacity)
      case .ready:
        MainShell()
          .transition(.opacity)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(palette.screen.ignoresSafeArea())
    .animation(.easeInOut(duration: 0.25), value: app.phase)
    .overlay { ToastOverlay() }
    .sheet(item: Binding(get: { app.prompts.first }, set: { _ in })) { request in
      ServerPromptSheet(request: request)
        .interactiveDismissDisabled()
    }
  }
}

/// "Talaria" set the way T3 Code sets its name: heavy first syllable, lighter rest.
struct Wordmark: View {
  var size: CGFloat = 21
  @Environment(\.palette) private var palette

  var body: some View {
    HStack(spacing: 0) {
      Text("Tal").font(AppFont.sans(size, .bold)).foregroundStyle(palette.wordmark)
      Text("aria").font(AppFont.sans(size, .medium)).foregroundStyle(palette.foregroundMuted)
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Talaria")
  }
}
