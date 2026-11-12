import SwiftUI

/// DM Sans at T3 Code's mobile type scale (11 / 12 / 13 / 14 / 16 / 18 / 21 / 26 / 30).
/// Sizes scale with Dynamic Type through `relativeTo`.
enum AppFont {
  enum Weight {
    case regular, medium, semibold, bold

    var postScriptName: String {
      switch self {
      case .regular: return "DMSans-Regular"
      case .medium: return "DMSans-Medium"
      case .semibold: return "DMSans-SemiBold"
      case .bold: return "DMSans-Bold"
      }
    }
  }

  static func sans(_ size: CGFloat, _ weight: Weight = .regular, relativeTo style: Font.TextStyle = .body) -> Font {
    .custom(weight.postScriptName, size: size, relativeTo: style)
  }

  static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
    .system(size: size, weight: weight, design: .monospaced)
  }

  static let micro = sans(11, relativeTo: .caption2)
  static let caption = sans(12, relativeTo: .caption)
  static let label = sans(13, relativeTo: .footnote)
  static let labelMedium = sans(13, .medium, relativeTo: .footnote)
  static let footnote = sans(14, relativeTo: .subheadline)
  static let footnoteMedium = sans(14, .medium, relativeTo: .subheadline)
  static let body = sans(16, relativeTo: .body)
  static let bodyMedium = sans(16, .medium, relativeTo: .body)
  static let bodySemibold = sans(16, .semibold, relativeTo: .body)
  static let headline = sans(18, .semibold, relativeTo: .headline)
  static let title = sans(21, .bold, relativeTo: .title3)
  static let largeTitle = sans(26, .bold, relativeTo: .title)
  static let display = sans(30, .bold, relativeTo: .largeTitle)
}

/// Shared spacing and radii so screens line up with each other.
enum Metrics {
  static let screenPadding: CGFloat = 18
  static let rowSpacing: CGFloat = 4
  static let cardRadius: CGFloat = 22
  static let bubbleRadius: CGFloat = 20
  static let controlRadius: CGFloat = 14
  static let hairline: CGFloat = 1 / 3
  /// Widest a column of reading text gets on iPad; wider lines are hard to follow.
  static let readableWidth: CGFloat = 760
}
