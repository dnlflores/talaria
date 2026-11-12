import Foundation

/// One bot in the inbox: its lead conversation, the others worth a look now, and how many
/// more it has.
public struct AgentGroup: Identifiable, Sendable, Equatable {
  public var id: String { profile }
  public let profile: String
  /// The pinned conversation, else the newest. Nil for a bot with no conversations yet.
  public var head: SessionSummary?
  /// Other conversations shown under the head: running, waiting, unread or active lately.
  public var recent: [SessionSummary]
  /// This bot's conversations that are not shown, including ones not loaded yet.
  public var moreCount: Int
  /// Newest sign of life across the bot's conversations, for ordering.
  public var latest: Double

  public var isPinned: Bool { head?.pinned == true }
  /// Something hangs under the head: shown conversations or a "more" row.
  public var hasTail: Bool { !recent.isEmpty || moreCount > 0 }
}

/// Groups the inbox by bot, the way the Hermes mobile app lists agents.
public enum AgentGrouping {
  /// A conversation touched within this window is shown under its bot's head.
  public static let recentWindow: Double = 86_400
  /// At most this many conversations under a head; the rest are "more".
  public static let maxRecent = 3
  /// Search shows this many matches under a head before "more".
  public static let maxMatches = 5

  /// - Parameters:
  ///   - sessions: every loaded conversation row, versions included.
  ///   - profiles: every bot, in the order to break ties in; bots that only appear in
  ///     `sessions` are added.
  ///   - totals: how many conversations each bot has on the Mac, for the rows not loaded.
  ///   - titles: display names, so a search for "Scout" finds the bot `scout`.
  ///   - isLive: a reply is running in, or waiting on, this conversation now.
  public static func groups(
    sessions: [SessionSummary], profiles: [String], families: [String: SessionFamily] = [:],
    totals: [String: Int] = [:], titles: [String: String] = [:], query: String = "",
    isLive: (String) -> Bool = { _ in false }, now: Double
  ) -> [AgentGroup] {
    let collapsed = SessionGrouping.collapse(sessions, families: families)
    let loaded = Dictionary(grouping: sessions, by: \.profile).mapValues(\.count)
    let byProfile = Dictionary(grouping: collapsed, by: \.profile)
    var names: [String] = []
    for name in profiles + collapsed.map(\.profile) where !names.contains(name) { names.append(name) }
    let needle = query.trimmingCharacters(in: .whitespaces).lowercased()

    var out: [AgentGroup] = []
    for name in names {
      let all = SessionGrouping.sorted(byProfile[name] ?? [])
      let unloaded = max(0, (totals[name] ?? 0) - (loaded[name] ?? 0))
      let latest = all.map { isLive($0.id) ? max(now, $0.recency) : $0.recency }.max() ?? 0

      if needle.isEmpty || matches(name: name, title: titles[name], needle: needle) {
        let head = all.first
        let rest = all.dropFirst()
        let worthALook = rest
          .filter { isLive($0.id) || $0.unread || now - $0.recency < recentWindow }
          .sorted { a, b in
            let (liveA, liveB) = (isLive(a.id), isLive(b.id))
            if liveA != liveB { return liveA }
            return a.recency > b.recency
          }
        let shown = Array(worthALook.prefix(maxRecent))
        out.append(AgentGroup(
          profile: name, head: head, recent: shown, moreCount: rest.count - shown.count + unloaded, latest: latest))
      } else {
        let found = all.filter { $0.matches(needle) }
        guard let head = found.first else { continue }
        let shown = Array(found.dropFirst().prefix(maxMatches))
        out.append(AgentGroup(
          profile: name, head: head, recent: shown, moreCount: found.count - 1 - shown.count, latest: latest))
      }
    }

    let order = Dictionary(uniqueKeysWithValues: names.enumerated().map { ($1, $0) })
    return out.sorted { a, b in
      if a.isPinned != b.isPinned { return a.isPinned }
      if (a.head == nil) != (b.head == nil) { return a.head != nil }
      if a.latest != b.latest { return a.latest > b.latest }
      return (order[a.profile] ?? 0) < (order[b.profile] ?? 0)
    }
  }

  private static func matches(name: String, title: String?, needle: String) -> Bool {
    name.lowercased().contains(needle) || (title?.lowercased().contains(needle) ?? false)
  }
}

/// One line of a conversation for a list: its latest reply, without Markdown.
public enum PreviewText {
  /// The last thing the assistant said, from the newest stored rows; nil before any reply.
  public static func lastReply(fromStoredRows rows: [JSONValue]) -> String? {
    let items = TranscriptItem.items(fromStoredRows: rows)
    guard let reply = items.last(where: { $0.kind == .assistant && !oneLine($0.text).isEmpty }) else { return nil }
    return oneLine(reply.text)
  }

  /// Markdown flattened to one plain line: no code fences, emphasis, headings, quotes,
  /// list marks, link targets or `MEDIA:` tags.
  public static func oneLine(_ markdown: String, limit: Int = 220) -> String {
    var lines: [String] = []
    var inFence = false
    for raw in FileExtraction.hidingMediaLines(markdown).split(separator: "\n", omittingEmptySubsequences: true) {
      var line = raw.trimmingCharacters(in: .whitespaces)
      if line.hasPrefix("```") || line.hasPrefix("~~~") {
        inFence.toggle()
        continue
      }
      if inFence { continue }
      line = line.replacing(/^(#{1,6}|>+|[-*+]|\d+[.)])\s+/, with: "")
      line = line.replacing(/!?\[([^\]]*)\]\([^)]*\)/) { String($0.output.1) }
      line = line.replacing(/(\*\*|__|`)/, with: "")
      line = line.replacing(/(^|\s)[*_]([^*_\s][^*_]*)[*_](?=\s|$|[.,;:!?])/) { "\($0.output.1)\($0.output.2)" }
      line = line.trimmingCharacters(in: .whitespaces)
      if line.isEmpty || line.allSatisfy({ "-*_|: ".contains($0) }) { continue }
      lines.append(line)
    }
    let joined = lines.joined(separator: " ").replacing(/\s+/, with: " ")
    return joined.count > limit ? String(joined.prefix(limit - 1)) + "…" : joined
  }
}
