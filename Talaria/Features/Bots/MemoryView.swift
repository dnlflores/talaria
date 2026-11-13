import HermesKit
import SwiftUI

// Memory & Learning: what Hermes has learned for a bot, drawn as a constellation (skills and
// memory notes as stars, lines where one relates to another), then the skills by use and the notes.

struct MemoryView: View {
  let profile: String
  @Environment(AppModel.self) private var app
  @Environment(\.palette) private var palette
  @State private var graph: LearningGraph?
  @State private var positions: [String: ConstellationLayout.Point] = [:]
  @State private var error: String?
  @State private var selected: String?
  @State private var expandedNotes: Set<String> = []

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 24) {
        if let graph {
          if graph.nodes.isEmpty {
            EmptyStateView(
              symbol: "brain", title: "Nothing learned yet",
              text: "Skills \(app.title(forProfile: profile)) writes or uses, and what it remembers, show up here.")
          } else {
            ConstellationCard(graph: graph, positions: positions, selected: $selected, profile: profile)
            skills(graph)
            notes(graph)
          }
        } else if let error {
          EmptyStateView(symbol: "brain", title: "Can't load what it learned", text: error)
        } else {
          ProgressView().frame(maxWidth: .infinity).padding(.top, 80)
        }
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 12)
      .frame(maxWidth: 680)
      .frame(maxWidth: .infinity)
    }
    .background(palette.screen.ignoresSafeArea())
    .navigationTitle("Memory & Learning")
    .navigationBarTitleDisplayMode(.inline)
    .refreshable { await load() }
    .task { if graph == nil { await load() } }
  }

  private func load() async {
    guard let client = app.client else { return }
    do {
      let fresh = try await client.learningGraph(profile: profile)
      // The layout is a few hundred passes over every pair: keep it off the main thread.
      let placed = await Task.detached(priority: .userInitiated) {
        ConstellationLayout.positions(for: fresh, spacing: 150)
      }.value
      positions = placed
      graph = fresh
      error = nil
    } catch {
      self.error = error.localizedDescription
    }
  }

  @ViewBuilder
  private func skills(_ graph: LearningGraph) -> some View {
    let skills = graph.skillsByUse
    if !skills.isEmpty {
      GroupedSection("Skills", trailing: "\(skills.count)") {
        ForEach(Array(skills.enumerated()), id: \.element.id) { offset, node in
          if offset > 0 { IconRowDivider() }
          NavigationLink(value: HubRoute.learning(profile: profile, id: node.id, title: node.label)) {
            LearningRow(node: node)
          }
          .buttonStyle(RowButtonStyle())
          .accessibilityIdentifier("learning.skill")
        }
      }
    }
  }

  @ViewBuilder
  private func notes(_ graph: LearningGraph) -> some View {
    if !graph.memory.isEmpty {
      GroupedSection("Memories", trailing: "\(graph.memory.count)") {
        ForEach(Array(graph.memory.enumerated()), id: \.element.id) { offset, card in
          if offset > 0 { IconRowDivider() }
          let isOpen = expandedNotes.contains(card.id)
          Button {
            withAnimation(.snappy(duration: 0.25)) {
              if isOpen { expandedNotes.remove(card.id) } else { expandedNotes.insert(card.id) }
            }
          } label: {
            HStack(alignment: .firstTextBaseline, spacing: 14) {
              RowSymbol(name: card.isAboutYou ? "person" : "text.quote")
              VStack(alignment: .leading, spacing: 3) {
                Text(card.body.isEmpty ? card.title : card.body)
                  .font(AppFont.footnote)
                  .foregroundStyle(palette.foreground)
                  .lineLimit(isOpen ? nil : 3)
                  .multilineTextAlignment(.leading)
                  .fixedSize(horizontal: false, vertical: true)
                  .textSelection(.enabled)
                Text(card.isAboutYou ? "About you" : "Note")
                  .font(AppFont.caption)
                  .foregroundStyle(palette.foregroundMuted)
              }
              Spacer(minLength: 0)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 13)
            .contentShape(Rectangle())
          }
          .buttonStyle(RowButtonStyle())
          .accessibilityIdentifier("learning.note")
        }
      }
    }
  }
}

/// A skill in the list: its name, its category and how often it was used.
private struct LearningRow: View {
  let node: LearningGraph.Node
  @Environment(\.palette) private var palette

  var body: some View {
    HStack(spacing: 14) {
      RowSymbol(name: "cube")
      VStack(alignment: .leading, spacing: 2) {
        Text(node.label)
          .font(AppFont.sans(16))
          .foregroundStyle(palette.foreground)
          .lineLimit(1)
        Text(LearningRow.detail(node))
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
    .frame(minHeight: 58)
    .contentShape(Rectangle())
  }

  static func detail(_ node: LearningGraph.Node) -> String {
    var parts: [String] = []
    if !node.category.isEmpty { parts.append(LearningGraph.categoryTitle(node.category)) }
    parts.append(node.useCount == 1 ? "1 use" : "\(node.useCount.formatted()) uses")
    if node.isLearned { parts.append("written by Hermes") }
    if node.state == "stale" { parts.append("stale") }
    return parts.joined(separator: " · ")
  }
}

/// The constellation on a card: drag to move around, pinch to zoom, tap a star to see what it is
/// linked to.
private struct ConstellationCard: View {
  let graph: LearningGraph
  let positions: [String: ConstellationLayout.Point]
  @Binding var selected: String?
  let profile: String
  @Environment(\.palette) private var palette
  @State private var pan: CGSize = .zero
  @State private var zoom: CGFloat = 0
  @GestureState private var dragging: CGSize = .zero
  @GestureState private var pinching: CGFloat = 1
  @State private var size: CGSize = .zero
  private let height: CGFloat = 430

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
        Text("\(graph.nodes.count)")
          .font(AppFont.sans(17))
          .foregroundStyle(palette.foregroundMuted)
      }
      .padding(.horizontal, 18)
      .padding(.top, 16)
      .padding(.bottom, 6)
      .accessibilityElement(children: .combine)
      .accessibilityIdentifier("constellation.header")

      map
        .frame(height: height)
        .clipped()

      if let node = selectedNode {
        GroupDivider(inset: 0)
        NavigationLink(value: HubRoute.learning(profile: profile, id: node.id, title: pageTitle(of: node))) {
          HStack(spacing: 12) {
            RowSymbol(name: node.kind == .skill ? "cube" : "text.quote")
            VStack(alignment: .leading, spacing: 2) {
              Text(title(of: node))
                .font(AppFont.sans(16, .medium))
                .foregroundStyle(palette.foreground)
                .lineLimit(2)
              Text(caption(of: node))
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
      }
    }
    .glassCard()
  }

  private var selectedNode: LearningGraph.Node? {
    guard let selected else { return nil }
    return graph.nodes.first { $0.id == selected }
  }

  private func pageTitle(of node: LearningGraph.Node) -> String {
    guard node.kind == .memory else { return node.label }
    return node.memorySource == "profile" ? "About you" : "Memory note"
  }

  private func title(of node: LearningGraph.Node) -> String {
    node.kind == .memory ? String(node.label.prefix(80)) : node.label
  }

  private func caption(of node: LearningGraph.Node) -> String {
    let links = graph.neighbours(of: node.id).count
    let linked = links == 1 ? "1 link" : "\(links) links"
    if node.kind == .memory { return "\(node.memorySource == "profile" ? "About you" : "Memory note") · \(linked)" }
    return LearningRow.detail(node) + " · " + linked
  }

  // MARK: The map

  private var scale: CGFloat {
    let base = zoom > 0 ? zoom : fitScale
    return min(max(base * pinching, 0.3), 2.2)
  }

  /// Small graphs fit the card; big ones open readable, a drag away from the rest.
  private var fitScale: CGFloat {
    guard size.width > 0, !positions.isEmpty else { return 0.8 }
    let xs = positions.values.map(\.x)
    let ys = positions.values.map(\.y)
    let width = (xs.max() ?? 0) - (xs.min() ?? 0) + 160
    let height = (ys.max() ?? 0) - (ys.min() ?? 0) + 120
    let fit = min(size.width / CGFloat(width), self.height / CGFloat(height))
    return min(max(fit, 0.85), 1)
  }

  private var offset: CGSize {
    CGSize(width: pan.width + dragging.width, height: pan.height + dragging.height)
  }

  private func point(_ id: String) -> CGPoint? {
    guard let position = positions[id] else { return nil }
    return CGPoint(
      x: size.width / 2 + CGFloat(position.x) * scale + offset.width,
      y: height / 2 + CGFloat(position.y) * scale + offset.height)
  }

  private var map: some View {
    let focus: Set<String> = selected.map { graph.neighbours(of: $0).union([$0]) } ?? []
    return ZStack {
      RadialGradient(
        colors: [palette.primary.opacity(0.10), palette.primary.opacity(0.03)], center: .center, startRadius: 10,
        endRadius: 360)
        .contentShape(Rectangle())
        .onTapGesture { withAnimation(.snappy(duration: 0.2)) { selected = nil } }

      Canvas { context, _ in
        for edge in graph.edges {
          guard let a = point(edge.source), let b = point(edge.target) else { continue }
          var path = Path()
          path.move(to: a)
          path.addLine(to: b)
          let isFocused = selected != nil && focus.contains(edge.source) && focus.contains(edge.target)
            && (edge.source == selected || edge.target == selected)
          let alpha: Double = selected == nil ? 0.32 : (isFocused ? 0.85 : 0.08)
          context.stroke(path, with: .color(palette.primary.opacity(alpha)), lineWidth: isFocused ? 1.6 : 1)
        }
      }
      .allowsHitTesting(false)

      ForEach(graph.nodes) { node in
        if let at = point(node.id) {
          ConstellationStar(
            node: node, isSelected: node.id == selected, isDimmed: selected != nil && !focus.contains(node.id)
          ) {
            UISelectionFeedbackGenerator().selectionChanged()
            withAnimation(.snappy(duration: 0.2)) { selected = selected == node.id ? nil : node.id }
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

/// One star: a skill as a cube on a white disc with its name under it, a memory note as a small
/// disc.
private struct ConstellationStar: View {
  let node: LearningGraph.Node
  let isSelected: Bool
  let isDimmed: Bool
  let action: () -> Void
  @Environment(\.palette) private var palette

  var body: some View {
    Button(action: action) {
      // The disc sits exactly on the star's point; the name hangs under it without moving it.
      Image(systemName: node.kind == .skill ? "cube" : "text.quote")
        .font(.system(size: node.kind == .skill ? 18 : 11, weight: .regular))
        .foregroundStyle(isSelected ? palette.primaryText : palette.icon)
        .frame(width: diameter, height: diameter)
        .background(isSelected ? palette.selectionFill : palette.card, in: Circle())
        .overlay {
          Circle().strokeBorder(isSelected ? palette.selectionStroke : palette.border, lineWidth: isSelected ? 1.5 : 1)
        }
        .shadow(color: palette.cardShadow, radius: 6, y: 3)
        .overlay(alignment: .top) {
          if node.kind == .skill {
            Text(node.label.replacingOccurrences(of: "-", with: "-\u{200B}"))
              .font(AppFont.sans(13))
              .foregroundStyle(palette.foreground)
              .multilineTextAlignment(.center)
              .lineLimit(2)
              .padding(.horizontal, 8)
              .padding(.vertical, 4)
              .background(palette.card.opacity(0.92), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
              .frame(width: 128)
              .fixedSize(horizontal: false, vertical: true)
              .offset(y: diameter + 6)
          }
        }
        .opacity(isDimmed ? 0.3 : 1)
    }
    .buttonStyle(.plain)
    .accessibilityLabel(node.kind == .skill ? "\(node.label), skill" : "Memory note: \(node.label)")
    .accessibilityAddTraits(isSelected ? .isSelected : [])
    .accessibilityIdentifier("constellation.star")
  }

  private var diameter: CGFloat { node.kind == .skill ? 44 : 26 }
}

/// A skill's SKILL.md or a memory note in full.
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
          EmptyStateView(symbol: "cube", title: "Can't open this", text: error)
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
