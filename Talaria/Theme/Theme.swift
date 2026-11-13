import SwiftUI

/// The color families: Hermes (the default look) and the six ported from T3 Code's mobile app,
/// each with a light and a dark palette.
enum ThemeFamily: String, CaseIterable, Identifiable, Sendable {
  case hermes
  case standard
  case t3Chat
  case grove
  case ocean
  case ember
  case iris

  var id: String { rawValue }

  var name: String {
    switch self {
    case .hermes: return "Hermes"
    case .standard: return "Classic"
    case .t3Chat: return "Orchid"
    case .grove: return "Grove"
    case .ocean: return "Ocean"
    case .ember: return "Ember"
    case .iris: return "Iris"
    }
  }

  func palette(for scheme: ColorScheme) -> Palette {
    switch (self, scheme) {
    case (.hermes, .dark): return .hermesDark
    case (.hermes, _): return .hermesLight
    case (.standard, .dark): return .standardDark
    case (.standard, _): return .standardLight
    case (.t3Chat, .dark): return .t3ChatDark
    case (.t3Chat, _): return .t3ChatLight
    case (.grove, .dark): return .groveDark
    case (.grove, _): return .groveLight
    case (.ocean, .dark): return .oceanDark
    case (.ocean, _): return .oceanLight
    case (.ember, .dark): return .emberDark
    case (.ember, _): return .emberLight
    case (.iris, .dark): return .irisDark
    case (.iris, _): return .irisLight
    }
  }
}

enum AppearanceMode: String, CaseIterable, Identifiable, Sendable {
  case system
  case light
  case dark

  var id: String { rawValue }

  var name: String {
    switch self {
    case .system: return "System"
    case .light: return "Light"
    case .dark: return "Dark"
    }
  }

  var colorScheme: ColorScheme? {
    switch self {
    case .system: return nil
    case .light: return .light
    case .dark: return .dark
    }
  }
}

extension EnvironmentValues {
  /// The active palette. Views read colors from here, never from literals.
  @Entry var palette: Palette = .standardLight
}

extension Palette {
  /// Semantic transcript accents stay distinct from every family's brand color.
  /// Dynamic providers follow the effective scheme, including an in-app override.
  var transcriptTool: Color {
    Color(uiColor: UIColor { traits in
      traits.userInterfaceStyle == .dark
        ? UIColor(red: 0.44, green: 0.81, blue: 0.87, alpha: 1)
        : UIColor(red: 0, green: 0.36, blue: 0.44, alpha: 1)
    })
  }

  var transcriptReasoning: Color {
    Color(uiColor: UIColor { traits in
      traits.userInterfaceStyle == .dark
        ? UIColor(red: 0.77, green: 0.67, blue: 0.94, alpha: 1)
        : UIColor(red: 0.40, green: 0.27, blue: 0.61, alpha: 1)
    })
  }

  /// Lavender fill and indigo edge of a selected chip.
  var selectionFill: Color { primary.opacity(0.2) }
  var selectionStroke: Color { primary.opacity(0.85) }
  /// The quieter tint of the thing in use (the current model's card).
  var currentFill: Color { primary.opacity(0.08) }
  var currentStroke: Color { primary.opacity(0.26) }
  /// The hairline edge and soft shadow of a frosted card.
  var cardStroke: Color { border }
  var cardShadow: Color {
    Color(uiColor: UIColor { traits in
      traits.userInterfaceStyle == .dark ? UIColor(white: 0, alpha: 0.45) : UIColor(white: 0, alpha: 0.07)
    })
  }
  /// A starred model.
  var star: Color { Color(.sRGB, red: 0.96, green: 0.76, blue: 0.13, opacity: 1) }

  /// Status colors the T3 token set expresses as adaptive ramps; fixed here per scheme.
  var success: Color { Color(.sRGB, red: 0.06, green: 0.69, blue: 0.45, opacity: 1) }
  var successSurface: Color { success.opacity(0.14) }
  var diffAdded: Color { Color(.sRGB, red: 0.06, green: 0.69, blue: 0.45, opacity: 0.16) }
  var diffRemoved: Color { Color(.sRGB, red: 0.94, green: 0.27, blue: 0.27, opacity: 0.16) }
}

/// Resolves the palette from the user's family and the effective color scheme, and applies
/// the app-wide defaults (tint, body font, background).
struct ThemedRoot<Content: View>: View {
  let family: ThemeFamily
  let appearance: AppearanceMode
  @ViewBuilder var content: Content
  @Environment(\.colorScheme) private var systemScheme

  var body: some View {
    let palette = family.palette(for: appearance.colorScheme ?? systemScheme)
    content
      .environment(\.palette, palette)
      .environment(\.font, AppFont.body)
      .tint(palette.primary)
      .foregroundStyle(palette.foreground)
      .background(palette.screen.ignoresSafeArea())
      .preferredColorScheme(appearance.colorScheme)
  }
}
