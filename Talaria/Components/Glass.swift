import HermesKit
import SwiftUI

// The pieces of the Hermes look: frosted cards, rows with a line icon, chips, the floating
// round buttons.

extension View {
  /// A frosted card: the grouped surface with a hairline edge and a soft shadow.
  func glassCard(radius: CGFloat = Metrics.cardRadius, fill: Color? = nil, stroke: Color? = nil, shadow: Bool = true)
    -> some View
  {
    modifier(GlassCard(radius: radius, fill: fill, stroke: stroke, shadow: shadow))
  }
}

private struct GlassCard: ViewModifier {
  let radius: CGFloat
  let fill: Color?
  let stroke: Color?
  let shadow: Bool
  @Environment(\.palette) private var palette

  func body(content: Content) -> some View {
    let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
    content
      .background(fill ?? palette.groupedCard, in: shape)
      .clipShape(shape)
      .overlay { shape.strokeBorder(stroke ?? palette.cardStroke, lineWidth: 1) }
      .shadow(color: shadow ? palette.cardShadow : .clear, radius: 18, x: 0, y: 8)
  }
}

/// The line icon at the start of a row.
struct RowSymbol: View {
  let name: String
  var color: Color?
  @Environment(\.palette) private var palette

  var body: some View {
    Image(systemName: name)
      .font(.system(size: 19, weight: .regular))
      .symbolRenderingMode(.monochrome)
      .foregroundStyle(color ?? palette.icon)
      .frame(width: 26, alignment: .center)
      .accessibilityHidden(true)
  }
}

/// A row that opens something: a line icon, the name, what it holds (a count, the model in use),
/// and a chevron.
struct NavRow: View {
  let title: String
  var symbol: String?
  var value: String = ""
  /// A smaller second line under the value ("ChatGPT or Codex Subscription").
  var detail: String = ""
  var showsChevron = true
  var isLoading = false
  @Environment(\.palette) private var palette

  var body: some View {
    HStack(spacing: 14) {
      if let symbol { RowSymbol(name: symbol) }
      Text(title)
        .font(AppFont.sans(17))
        .foregroundStyle(palette.foreground)
        .lineLimit(1)
        .layoutPriority(1)
      Spacer(minLength: 10)
      if isLoading {
        ProgressView().controlSize(.small)
      } else if !value.isEmpty {
        VStack(alignment: .trailing, spacing: 1) {
          Text(value)
            .font(AppFont.sans(16))
            .foregroundStyle(palette.foregroundMuted)
            .lineLimit(1)
          if !detail.isEmpty {
            Text(detail)
              .font(AppFont.caption)
              .foregroundStyle(palette.foregroundTertiary)
              .lineLimit(1)
          }
        }
      }
      if showsChevron {
        Image(systemName: "chevron.right")
          .font(.system(size: 13, weight: .semibold))
          .foregroundStyle(palette.chevron)
      }
    }
    .padding(.horizontal, 18)
    .frame(minHeight: 58)
    .contentShape(Rectangle())
    .accessibilityElement(children: .combine)
  }
}

/// The hairline between rows that carry a line icon: it starts where the text does.
struct IconRowDivider: View {
  var body: some View {
    GroupDivider(inset: 18 + 26 + 14)
  }
}

/// A rounded pill that filters a list: a provider of models, a kanban column.
struct Chip: View {
  enum Style { case title, caps }
  let title: String
  var count: Int?
  var isSelected: Bool
  var style: Style = .title
  /// A dot after the count: the provider of the model in use.
  var marksCurrent = false
  let action: () -> Void
  @Environment(\.palette) private var palette

  var body: some View {
    Button(action: action) {
      HStack(spacing: 7) {
        Text(style == .caps ? title.uppercased() : title)
          .font(style == .caps ? AppFont.sans(13, .semibold) : AppFont.sans(15, .semibold))
          .kerning(style == .caps ? 1.6 : 0)
          .foregroundStyle(isSelected ? palette.foreground : palette.foregroundMuted)
          .lineLimit(1)
        if let count {
          Text("\(count)")
            .font(AppFont.sans(style == .caps ? 13 : 14))
            .foregroundStyle(isSelected ? palette.foregroundSecondary : palette.foregroundTertiary)
        }
        if marksCurrent {
          Circle().fill(palette.primaryText).frame(width: 6, height: 6)
        }
      }
      .padding(.horizontal, 15)
      .frame(height: 38)
      .background(isSelected ? palette.selectionFill : palette.subtle, in: Capsule())
      .overlay {
        Capsule().strokeBorder(isSelected ? palette.selectionStroke : palette.border, lineWidth: isSelected ? 1.5 : 1)
      }
      .contentShape(Capsule())
    }
    .buttonStyle(.plain)
    .accessibilityAddTraits(isSelected ? .isSelected : [])
  }
}

/// A provider's mark in the model lists: its initial on a soft tile in a color of its own.
struct ProviderMark: View {
  let provider: String
  var name: String = ""
  var size: CGFloat = 34
  @Environment(\.palette) private var palette

  var body: some View {
    let hue = AvatarView.hue(for: provider)
    let initial = String((name.isEmpty ? provider : name).prefix(1)).uppercased()
    Text(initial)
      .font(AppFont.sans(size * 0.44, .bold))
      .foregroundStyle(Color(hue: hue, saturation: 0.55, brightness: 0.55))
      .frame(width: size, height: size)
      .background(Color(hue: hue, saturation: 0.35, brightness: 0.95).opacity(0.55), in: Circle())
      .overlay { Circle().strokeBorder(palette.border, lineWidth: 1) }
      .accessibilityHidden(true)
  }
}

/// A round floating button in Liquid Glass: back, a page's own action.
struct GlassCircleButton: View {
  let symbol: String
  let label: String
  var size: CGFloat = 50
  var tint: Color?
  var fill: Color?
  let action: () -> Void
  @Environment(\.palette) private var palette

  var body: some View {
    Button(action: action) {
      Image(systemName: symbol)
        .font(.system(size: size * 0.4, weight: .medium))
        .foregroundStyle(tint ?? palette.foreground)
        .frame(width: size, height: size)
        .contentShape(Circle())
    }
    .buttonStyle(.plain)
    .glassEffect(fill.map { .regular.tint($0).interactive() } ?? .regular.interactive(), in: .circle)
    .accessibilityLabel(label)
  }
}

/// A search field as a frosted pill, for lists that are not under a navigation bar's search.
struct GlassSearchField: View {
  let prompt: String
  @Binding var text: String
  @FocusState private var isFocused: Bool
  @Environment(\.palette) private var palette

  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: "magnifyingglass")
        .font(.system(size: 17, weight: .medium))
        .foregroundStyle(palette.icon)
      TextField(prompt, text: $text)
        .font(AppFont.sans(17))
        .focused($isFocused)
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .submitLabel(.search)
      if !text.isEmpty {
        Button {
          text = ""
        } label: {
          Image(systemName: "xmark.circle.fill")
            .font(.system(size: 16))
            .foregroundStyle(palette.iconMuted)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Clear search")
      }
    }
    .padding(.horizontal, 16)
    .frame(height: 50)
    .glassCard(radius: 25, fill: palette.card, shadow: false)
    .contentShape(Capsule())
    .onTapGesture { isFocused = true }
  }
}
