import HermesKit
import SwiftUI

// Memory & Learning: what a bot remembers, drawn as a constellation of titled memories linked
// where they talk about the same things, then every memory in a list.

struct MemoryView: View {
  let profile: String
  @Environment(AppModel.self) private var app
  @Environment(\.palette) private var palette
  @State private var graph: LearningGraph?
  @State private var notes: [MemoryNote]?
  @State private var width: CGFloat = 0
  @State private var web = LearningGraph(nodes: [], edges: [])
  @State private var positions: [String: ConstellationLayout.Point] = [:]
  @State private var error: String?
  @State private var selected: String?

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 24) {
        if let notes {
          if notes.isEmpty {
            EmptyStateView(
              symbol: "brain", title: "No memories yet",
              text: "What \(app.title(forProfile: profile)) remembers about you and your work shows up here.")
          } else {
            ConstellationCard(web: web, notes: notes, positions: positions, selected: $selected, profile: profile)
            memoryList(notes)
          }
        } else if let error {
          EmptyStateView(symbol: "brain", title: "Can't load memories", text: error)
        } else {
          ProgressView().frame(maxWidth: .infinity).padding(.top, 80)
        }
      }
      .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
      .padding(.horizontal, 16)
      .padding(.vertical, 12)
      .frame(maxWidth: 680)
      .frame(maxWidth: .infinity)
    }
    .background(palette.screen.ignoresSafeArea())
    .navigationTitle("Memory & Learning")
    .navigationBarTitleDisplayMode(.inline)
    .refreshable { await load() }
    .task { if notes == nil { await load() } }
    .task(id: notes?.map(\.titleKey) ?? []) {
      if let notes { await app.memoryTitles.name(notes) }
    }
    // Laid out for the card's shape, again when it changes (an iPad turning).
    .task(id: "\(notes?.map(\.id).joined(separator: ",") ?? "")|\(Int(width / 24))") { await layout() }
  }

  private func load() async {
    guard let client = app.client else { return }
    do {
      let fresh = try await client.learningGraph(profile: profile)
      let freshNotes = fresh.memoryNotes
      graph = fresh
      notes = freshNotes
      if let selected, !freshNotes.contains(where: { $0.id == selected }) { self.selected = nil }
      error = nil
    } catch {
      self.error = error.localizedDescription
    }
  }

  /// Links the memories and places them, off the main thread: both are passes over every pair.
  private func layout() async {
    guard let graph, width > 0 else { return }
    let room = MemoryStar.room
    let aspect = Double(ConstellationCard.mapHeight / width)
    let (freshWeb, placed) = await Task.detached(priority: .userInitiated) {
      let web = graph.memoryWeb
      return (web, ConstellationLayout.positions(for: web, spacing: 150, room: room, aspect: aspect))
    }.value
    guard !Task.isCancelled else { return }
    web = freshWeb
    positions = placed
  }

  private func memoryList(_ notes: [MemoryNote]) -> some View {
    GroupedSection("Memories", trailing: "\(notes.count)") {
      ForEach(Array(notes.enumerated()), id: \.element.id) { offset, note in
        if offset > 0 { IconRowDivider() }
        NavigationLink(value: HubRoute.learning(profile: profile, id: note.id, title: app.memoryTitles.title(for: note))) {
          MemoryRow(note: note, title: app.memoryTitles.title(for: note))
        }
        .buttonStyle(RowButtonStyle())
        .accessibilityIdentifier("learning.note")
      }
    }
  }
}

extension MemoryNote {
  /// A memory's star: a person for what it knows about you, a note for the rest.
  var symbol: String { isAboutYou ? "person" : "note.text" }
  var kindName: String { isAboutYou ? "About you" : "Note" }
}

/// A memory in the list: its title, the start of what it says, and whether it is about you.
private struct MemoryRow: View {
  let note: MemoryNote
  let title: String
  @Environment(\.palette) private var palette

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 14) {
      RowSymbol(name: note.symbol)
      VStack(alignment: .leading, spacing: 3) {
        Text(title)
          .font(AppFont.sans(16, .medium))
          .foregroundStyle(palette.foreground)
          .lineLimit(1)
          .contentTransition(.opacity)
        Text(note.text)
          .font(AppFont.footnote)
          .foregroundStyle(palette.foregroundMuted)
          .lineLimit(2)
          .multilineTextAlignment(.leading)
        Text(note.kindName)
          .font(AppFont.caption)
          .foregroundStyle(palette.foregroundTertiary)
      }
      Spacer(minLength: 8)
      Image(systemName: "chevron.right")
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(palette.chevron)
    }
    .padding(.horizontal, 18)
    .padding(.vertical, 13)
    .contentShape(Rectangle())
    .accessibilityElement(children: .combine)
  }
}

/// The constellation on a card: drag to move around, pinch to zoom, tap a memory to light up the
/// ones it is linked to.
private struct ConstellationCard: View {
  let web: LearningGraph
  let notes: [MemoryNote]
  let positions: [String: ConstellationLayout.Point]
  @Binding var selected: String?
  let profile: String
  @Environment(AppModel.self) private var app
  @Environment(\.palette) private var palette
  @State private var pan: CGSize = .zero
  @State private var zoom: CGFloat = 0
  @GestureState private var dragging: CGSize = .zero
  @GestureState private var pinching: CGFloat = 1
  @State private var size: CGSize = .zero
  static let mapHeight: CGFloat = 470
  private var height: CGFloat { Self.mapHeight }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 10) {
        Image(systemName: "point.3.connected.trianglepath.dotted")
          .font(.system(size: 17, weight: .regular))
          .foregroundStyle(palette.icon)
        Text("Your Constellation")
          .font(AppFont.sans(18, .medium))
          .foregroundStyle(palette.foreground)
        Spacer(minLength: 8)
        if app.memoryTitles.isNaming {
          ProgressView().controlSize(.mini)
            .accessibilityLabel("Naming memories")
        }
        Text("\(notes.count)")
          .font(AppFont.sans(17))
          .foregroundStyle(palette.foregroundMuted)
      }
      .padding(.horizontal, 18)
      .padding(.top, 16)
      .padding(.bottom, 6)
      .accessibilityElement(children: .combine)
      .accessibilityValue(app.memoryTitles.isNaming ? "naming" : "")
      .accessibilityIdentifier("constellation.header")

      map
        .frame(height: height)
        .clipped()

      GroupDivider(inset: 0)
      if let note = selectedNote {
        NavigationLink(value: HubRoute.learning(profile: profile, id: note.id, title: title(note))) {
          HStack(spacing: 12) {
            RowSymbol(name: note.symbol)
            VStack(alignment: .leading, spacing: 2) {
              Text(title(note))
                .font(AppFont.sans(16, .medium))
                .foregroundStyle(palette.foreground)
                .lineLimit(1)
              Text(caption(note))
                .font(AppFont.caption)
                .foregroundStyle(palette.foregroundMuted)
                .lineLimit(1)
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
              .font(.system(size: 13, weight: .semibold))
              .foregroundStyle(palette.chevron)
          }
          .padding(.horizontal, 18)
          .padding(.vertical, 12)
          .contentShape(Rectangle())
        }
        .buttonStyle(RowButtonStyle())
        .accessibilityIdentifier("constellation.selected")
      } else {
        Text("Memories are linked when they talk about the same things. Tap one to see its links.")
          .font(AppFont.caption)
          .foregroundStyle(palette.foregroundMuted)
          .padding(.horizontal, 18)
          .padding(.vertical, 12)
      }
    }
    .glassCard()
  }

  private var selectedNote: MemoryNote? {
    guard let selected else { return nil }
    return notes.first { $0.id == selected }
  }

  private func title(_ note: MemoryNote) -> String { app.memoryTitles.title(for: note) }

  private func caption(_ note: MemoryNote) -> String {
    let links = web.neighbours(of: note.id).count
    let linked = links == 0 ? "no links" : links == 1 ? "linked to 1 memory" : "linked to \(links) memories"
    return "\(note.kindName) · \(linked)"
  }

  // MARK: The map

  private var scale: CGFloat {
    let base = zoom > 0 ? zoom : fitScale
    return min(max(base * pinching, 0.3), 2.2)
  }

  /// The layout's extent, star centers only.
  private var bounds: (minX: CGFloat, maxX: CGFloat, minY: CGFloat, maxY: CGFloat) {
    let xs = positions.values.map { CGFloat($0.x) }
    let ys = positions.values.map { CGFloat($0.y) }
    return (xs.min() ?? 0, xs.max() ?? 0, ys.min() ?? 0, ys.max() ?? 0)
  }

  /// Small webs fit the card; big ones open readable, a drag away from the rest. Never below the
  /// scale the layout made room for (`MemoryStar.minimumScale`), or names would overlap.
  private var fitScale: CGFloat {
    guard size.width > 0, !positions.isEmpty else { return 1 }
    let b = bounds
    let fitX = (size.width - MemoryStar.labelWidth - 16) / max(b.maxX - b.minX, 1)
    let fitY = (height - MemoryStar.reachAbove - MemoryStar.reachBelow - 16) / max(b.maxY - b.minY, 1)
    return min(max(min(fitX, fitY), MemoryStar.minimumScale), 1)
  }

  private var offset: CGSize {
    CGSize(width: pan.width + dragging.width, height: pan.height + dragging.height)
  }

  /// A star's place on the card: the web, names included (they hang below the discs), centered.
  private func point(_ id: String) -> CGPoint? {
    guard let position = positions[id] else { return nil }
    let b = bounds
    let centerX = (b.minX + b.maxX) / 2 * scale
    let top = b.minY * scale - MemoryStar.reachAbove
    let bottom = b.maxY * scale + MemoryStar.reachBelow
    return CGPoint(
      x: size.width / 2 - centerX + CGFloat(position.x) * scale + offset.width,
      y: height / 2 - (top + bottom) / 2 + CGFloat(position.y) * scale + offset.height)
  }

  private var map: some View {
    let focus: Set<String> = selected.map { web.neighbours(of: $0).union([$0]) } ?? []
    return ZStack {
      RadialGradient(
        colors: [palette.primary.opacity(0.10), palette.primary.opacity(0.03)], center: .center, startRadius: 10,
        endRadius: 360)
        .contentShape(Rectangle())
        .onTapGesture { withAnimation(.snappy(duration: 0.2)) { selected = nil } }

      Canvas { context, _ in
        for edge in web.edges {
          guard let a = point(edge.source), let b = point(edge.target) else { continue }
          var path = Path()
          path.move(to: a)
          path.addLine(to: b)
          let isFocused = selected != nil && (edge.source == selected || edge.target == selected)
          let alpha: Double = selected == nil ? 0.38 : (isFocused ? 0.85 : 0.08)
          context.stroke(path, with: .color(palette.primary.opacity(alpha)), lineWidth: isFocused ? 1.8 : 1.1)
        }
      }
      .allowsHitTesting(false)

      ForEach(notes) { note in
        if let at = point(note.id) {
          MemoryStar(
            note: note, title: title(note), isSelected: note.id == selected,
            isDimmed: selected != nil && !focus.contains(note.id)
          ) {
            UISelectionFeedbackGenerator().selectionChanged()
            withAnimation(.snappy(duration: 0.2)) { selected = selected == note.id ? nil : note.id }
          }
          .position(at)
          // Drawing is clipped to the card but taps are not: a star past the edge stays inert.
          .allowsHitTesting(at.x > 0 && at.x < size.width && at.y > 0 && at.y < height)
        }
      }
    }
    .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
    .highPriorityGesture(
      DragGesture(minimumDistance: 6)
        .updating($dragging) { value, state, _ in state = value.translation }
        .onEnded { value in
          pan.width += value.translation.width
          pan.height += value.translation.height
        }
    )
    .simultaneousGesture(
      MagnifyGesture()
        .updating($pinching) { value, state, _ in state = value.magnification }
        .onEnded { value in
          let base = zoom > 0 ? zoom : fitScale
          zoom = min(max(base * value.magnification, 0.3), 2.2)
        }
    )
    .onTapGesture(count: 2) {
      withAnimation(.snappy(duration: 0.3)) {
        pan = .zero
        zoom = 0
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("constellation.map")
  }
}

/// One memory: a disc on the star's point, its title hanging under it.
private struct MemoryStar: View {
  let note: MemoryNote
  let title: String
  let isSelected: Bool
  let isDimmed: Bool
  let action: () -> Void
  @Environment(\.palette) private var palette

  static let diameter: CGFloat = 40
  static let labelWidth: CGFloat = 106
  /// How far a star reaches above and below its point: the disc's top, the bottom of a two-line name.
  static let reachAbove: CGFloat = diameter / 2
  static let reachBelow: CGFloat = diameter / 2 + 5 + 37
  /// The smallest scale the map draws at. Names keep their size when the map shrinks, so the
  /// layout leaves room for them at this scale.
  static let minimumScale: CGFloat = 0.85
  /// The box no other star may enter, in layout units.
  static var room: (width: Double, height: Double) {
    (Double(labelWidth + 10) / Double(minimumScale), Double(reachAbove + reachBelow + 10) / Double(minimumScale))
  }
  private var diameter: CGFloat { Self.diameter }

  var body: some View {
    Button(action: action) {
      Image(systemName: note.symbol)
        .font(.system(size: 16, weight: .regular))
        .foregroundStyle(isSelected ? palette.primaryText : palette.icon)
        .frame(width: diameter, height: diameter)
        .background(isSelected ? palette.selectionFill : palette.card, in: Circle())
        .overlay {
          Circle().strokeBorder(isSelected ? palette.selectionStroke : palette.border, lineWidth: isSelected ? 1.5 : 1)
        }
        .shadow(color: palette.cardShadow, radius: 6, y: 3)
        .overlay(alignment: .top) {
          Text(title)
            // A fixed size: the layout leaves room for names this big (`room`).
            .font(.custom(AppFont.Weight.regular.postScriptName, fixedSize: 12))
            .foregroundStyle(palette.foreground)
            .multilineTextAlignment(.center)
            .lineLimit(2)
            .minimumScaleFactor(0.8)
            .contentTransition(.opacity)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(palette.card.opacity(0.92), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .frame(width: Self.labelWidth)
            .fixedSize(horizontal: false, vertical: true)
            .offset(y: diameter + 5)
        }
        .opacity(isDimmed ? 0.3 : 1)
    }
    .buttonStyle(.plain)
    .accessibilityLabel("\(title), \(note.isAboutYou ? "about you" : "memory")")
    .accessibilityAddTraits(isSelected ? .isSelected : [])
    .accessibilityIdentifier("constellation.star")
  }
}

/// A memory in full (or, by its id, a skill's SKILL.md).
struct LearningNodeView: View {
  let profile: String
  let id: String
  let title: String
  @Environment(AppModel.self) private var app
  @Environment(\.palette) private var palette
  @State private var content: String?
  @State private var error: String?

  var body: some View {
    ScrollView {
      Group {
        if let content {
          MarkdownView(text: LearningNodeView.body(of: content), style: .note)
            .textSelection(.enabled)
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassCard()
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("learning.content")
        } else if let error {
          EmptyStateView(symbol: "note.text", title: "Can't open this", text: error)
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
    .navigationTitle(title)
    .navigationBarTitleDisplayMode(.inline)
    .task { await load() }
  }

  private func load() async {
    guard let client = app.client else { return }
    do {
      content = try await client.learningNode(id: id, profile: profile)
      error = nil
    } catch {
      self.error = error.localizedDescription
    }
  }

  /// A SKILL.md without its YAML front matter, which reads as noise on a phone.
  static func body(of text: String) -> String {
    guard text.hasPrefix("---\n"), let end = text.range(of: "\n---", range: text.index(text.startIndex, offsetBy: 4)..<text.endIndex)
    else { return text }
    return String(text[end.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
  }
}
