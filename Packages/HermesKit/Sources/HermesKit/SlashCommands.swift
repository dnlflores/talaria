import Foundation

/// A `/command` typed into the composer: `/` first, a bare name, then whitespace or the end.
/// `/usr/local` (a second slash) and `run /clean` (not at the start) are words, not commands.
/// Splits the way the desktop app does (`apps/shared/src/slash.ts`): the name is lower-cased and
/// the argument keeps its interior verbatim, new lines included.
public struct SlashInvocation: Sendable, Equatable {
  /// Lower-cased, without the slash. Empty for `/` or `/ words`.
  public let name: String
  /// What follows the name, outer whitespace removed.
  public let arg: String
  /// The whole command as typed, trimmed (`/work fix the leak`).
  public let typed: String

  /// Nil when the text is not a command.
  public init?(_ text: String) {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.hasPrefix("/") else { return nil }
    let rest = trimmed.dropFirst()
    let token = rest.prefix { !$0.isWhitespace }
    guard !token.contains("/") else { return nil }
    name = token.lowercased()
    arg = rest.dropFirst(token.count).trimmingCharacters(in: .whitespacesAndNewlines)
    typed = trimmed
  }

  /// `slash.exec`'s `command`: the typed text without its slash.
  public var command: String { String(typed.dropFirst()) }
}

/// One row of the `/` menu, from `complete.slash`.
public struct SlashCompletion: Sendable, Equatable, Identifiable {
  public enum Kind: Sendable, Equatable { case command, skill }

  /// With its slash: `/work`.
  public let name: String
  /// One line about it, without the CLI's ⚡ / ▣ / 🔌 marks.
  public let summary: String
  public let kind: Kind

  public var id: String { name }

  public init(name: String, summary: String, kind: Kind) {
    self.name = name
    self.summary = summary
    self.kind = kind
  }

  /// The rows of a `complete.slash` answer (`{items: [{text, display, meta, kind}], replace_from}`).
  /// Only command names are offered: an answer completing an argument (`replace_from` past the
  /// slash, as for `/personality `) gives none. Commands the phone leaves to the Mac are left out.
  public static func items(from result: JSONValue) -> [SlashCompletion] {
    if let replaceFrom = result["replace_from"].int, replaceFrom > 1 { return [] }
    var seen = Set<String>()
    var out: [SlashCompletion] = []
    for item in result["items"].array ?? [] {
      let text = item["text"].stringValue.trimmingCharacters(in: .whitespaces)
      let bare = text.hasPrefix("/") ? String(text.drop { $0 == "/" }) : text
      guard !bare.isEmpty, !bare.contains(where: \.isWhitespace) else { continue }
      let name = "/" + bare
      guard !SlashPolicy.isMacOnly(name), seen.insert(name.lowercased()).inserted else { continue }
      let meta = item["meta"].stringValue.trimmingCharacters(in: .whitespaces)
      let marked = skillMarks.contains { meta.hasPrefix($0) }
      let kind: Kind
      switch item["kind"].string {
      case "skill": kind = .skill
      case "command": kind = .command
      default: kind = marked ? .skill : .command
      }
      out.append(SlashCompletion(name: name, summary: summary(meta), kind: kind))
    }
    return out
  }

  /// The CLI marks skills ⚡, bundles ▣ and plugin commands 🔌 at the start of the description.
  static let skillMarks = ["⚡", "▣"]
  static let marks = ["⚡", "▣", "🔌"]

  static func summary(_ meta: String) -> String {
    var text = meta
    for mark in marks where text.hasPrefix(mark) {
      text = String(text.dropFirst(mark.count))
    }
    let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
    return line.trimmingCharacters(in: .whitespaces)
  }
}

/// The `/` menu: when it shows, and what picking a row leaves in the composer.
public enum SlashMenu {
  /// The `/token` to complete, or nil when no menu shows: the composer starts with `/` and holds
  /// one word so far. A space after the name, deleting the `/`, or sending hides it.
  public static func query(in draft: String) -> String? {
    guard draft.hasPrefix("/") else { return nil }
    let rest = draft.dropFirst()
    guard !rest.contains(where: { $0.isWhitespace || $0 == "/" }) else { return nil }
    return draft
  }

  /// Picking a row replaces the `/token` with the name and a space, ready for the argument.
  public static func picking(_ item: SlashCompletion) -> String {
    item.name + " "
  }
}

/// Which commands the phone runs. The desktop app handles many commands itself (a new chat, the
/// theme, pickers, its own dedicated calls, `apps/desktop/src/lib/desktop-slash-commands.ts`),
/// and some only make sense in a terminal. Those stay off the phone's menu, and typing one says to
/// run it on the Mac rather than sending it anywhere.
public enum SlashPolicy {
  /// The desktop app's own commands, aliases included; `/skills` runs on the gateway there too,
  /// and `/undo` is left to the gateway, which answers it with words to edit (`prefill`).
  static let desktopOwned: Set<String> = [
    "/new", "/reset", "/clear", "/stop", "/branch", "/fork", "/yolo", "/reasoning", "/wake", "/handoff",
    "/profile", "/skin", "/title", "/help", "/commands", "/browser", "/journey", "/learning", "/memory-graph",
    "/model", "/resume", "/sessions", "/switch", "/compress", "/compact", "/btw", "/bg", "/background",
    "/retry", "/steer", "/s", "/queue", "/q", "/pet", "/pets", "/hatch", "/generate-pet", "/rollback",
    "/agents", "/tasks", "/config", "/history", "/save", "/export", "/import", "/timestamps", "/ts",
    "/palette", "/status",
  ]
  /// Commands Hermes' registry gives no app surface at all (terminal, settings, voice), and the
  /// terminal UI's own display toggles.
  static let noAppSurface: Set<String> = [
    "/busy", "/copy", "/cron", "/curator", "/exit", "/fast", "/footer", "/gateway", "/image", "/indicator",
    "/insights", "/kanban", "/login", "/paste", "/platforms", "/plugins", "/quit", "/redraw", "/reload",
    "/reload-mcp", "/reload-skills", "/reload_mcp", "/reload_skills", "/restart", "/rewind", "/sb",
    "/set-home", "/sethome", "/snap", "/snapshot", "/statusbar", "/toolsets", "/update", "/verbose",
    "/voice", "/worktree", "/density", "/details", "/logs", "/mouse",
  ]

  /// `name` with or without its slash.
  public static func isMacOnly(_ name: String) -> Bool {
    let key = "/" + name.lowercased().drop { $0 == "/" }
    return desktopOwned.contains(key) || noAppSurface.contains(key)
  }
}

/// A structured answer from `command.dispatch`, or from `slash.exec` when it rerouted there
/// (`type` set). Mirrors `parseCommandDispatch` in the desktop app's shared code.
public enum SlashDirective: Sendable, Equatable {
  /// `exec` or `plugin`: text to show.
  case exec(output: String?)
  /// Another command's name: run that one with the same argument.
  case alias(target: String)
  /// A skill: `message` is the expanded skill for the model; `display` is the invocation to show.
  case skill(name: String, message: String?, display: String?)
  /// A message to send as the person's turn.
  case send(message: String, display: String?, notice: String?)
  /// Words for the composer, to edit before sending (`/undo`).
  case prefill(message: String, notice: String?)

  /// Nil when the answer has no known `type` or misses a field that type needs.
  public init?(_ json: JSONValue) {
    switch json["type"].string {
    case "exec", "plugin":
      self = .exec(output: json["output"].string)
    case "alias":
      guard let target = json["target"].string else { return nil }
      self = .alias(target: target)
    case "skill":
      guard let name = json["name"].string else { return nil }
      self = .skill(name: name, message: json["message"].string, display: json["display"].string)
    case "send":
      guard let message = json["message"].string else { return nil }
      self = .send(message: message, display: json["display"].string, notice: json["notice"].string)
    case "prefill":
      guard let message = json["message"].string else { return nil }
      self = .prefill(message: message, notice: json["notice"].string)
    default:
      return nil
    }
  }
}

/// What a slash command comes to on the phone.
public struct SlashResult: Sendable, Equatable {
  public enum Outcome: Sendable, Equatable {
    /// Start a turn with `message` (the expanded skill, or a message the command composed); the
    /// person's bubble shows `display`, never the expanded skill.
    case submit(message: String, display: String)
    /// Put `message` in the composer to edit.
    case prefill(String)
    /// Text shown under the command in the chat. Not sent to the model, not stored.
    case output(String)
    /// The phone leaves this command to the Mac.
    case macOnly
    /// The Mac's error, in words.
    case failure(String)
  }

  /// A line the gateway wants shown before the outcome (`/goal`'s "Goal set").
  public var notice: String?
  public var outcome: Outcome

  public init(notice: String? = nil, _ outcome: Outcome) {
    self.notice = notice
    self.outcome = outcome
  }
}

/// Runs a slash command the way the desktop app does (`use-prompt-actions/slash.ts`): `slash.exec`
/// first, and `command.dispatch` when that refuses (skills and bundles answer there). Only the
/// skill, send, prefill and plain-text paths are taken; everything else becomes a notice. A command
/// is never sent to the model as words: no path here returns the typed text for submitting.
public enum SlashRunner {
  /// `slash.exec {session_id, command}`, `command` without its slash.
  public typealias Exec = @Sendable (_ command: String) async throws -> JSONValue
  /// `command.dispatch {session_id, name, arg}`.
  public typealias Dispatch = @Sendable (_ name: String, _ arg: String) async throws -> JSONValue

  public static func run(_ invocation: SlashInvocation, exec: Exec, dispatch: Dispatch) async -> SlashResult {
    await run(invocation, exec: exec, dispatch: dispatch, hops: 0)
  }

  private static func run(_ invocation: SlashInvocation, exec: Exec, dispatch: Dispatch, hops: Int) async -> SlashResult {
    let name = invocation.name
    guard !name.isEmpty else {
      return SlashResult(notice: "Type a command name right after the /.", .prefill(invocation.typed))
    }
    if SlashPolicy.isMacOnly(name) { return SlashResult(.macOnly) }

    var execError: (any Error)?
    do {
      let answer = try await exec(invocation.command)
      if let directive = SlashDirective(answer) {
        return await handle(directive, invocation, exec: exec, dispatch: dispatch, hops: hops)
      }
      let body = answer["output"].string.flatMap { $0.isEmpty ? nil : $0 } ?? "/\(name): no output"
      let warning = answer["warning"].stringValue
      return SlashResult(.output(warning.isEmpty ? body : "warning: \(warning)\n\(body)"))
    } catch {
      // Skills and bundles are refused here on purpose; a worker crash is the real error, kept
      // for when the fallback has nothing to add.
      execError = error
    }

    do {
      let answer = try await dispatch(name, invocation.arg)
      guard let directive = SlashDirective(answer) else {
        return SlashResult(.failure("Unexpected answer from the Mac for /\(name)."))
      }
      return await handle(directive, invocation, exec: exec, dispatch: dispatch, hops: hops)
    } catch {
      let message = describe(error)
      // "Not a quick/plugin/skill command" only says the fallback had nothing to add.
      if let execError, message.range(of: #"not a quick/plugin/(bundle/)?skill command"#, options: [.regularExpression, .caseInsensitive]) != nil {
        return SlashResult(.failure("/\(name) failed: \(describe(execError))"))
      }
      return SlashResult(.failure(message))
    }
  }

  private static func handle(
    _ directive: SlashDirective, _ invocation: SlashInvocation, exec: Exec, dispatch: Dispatch, hops: Int
  ) async -> SlashResult {
    let name = invocation.name
    switch directive {
    case .exec(let output):
      let text = output.flatMap { $0.isEmpty ? nil : $0 } ?? "(no output)"
      return SlashResult(.output(text))
    case .alias(let target):
      let bare = target.drop { $0 == "/" }
      guard hops < 2, !bare.isEmpty,
        let next = SlashInvocation("/\(bare)" + (invocation.arg.isEmpty ? "" : " \(invocation.arg)"))
      else { return SlashResult(.failure("/\(name) points nowhere the phone can follow.")) }
      return await run(next, exec: exec, dispatch: dispatch, hops: hops + 1)
    case .prefill(let message, let notice):
      let words = message.trimmingCharacters(in: .whitespacesAndNewlines)
      let note = clean(notice)
      if words.isEmpty { return SlashResult(.output(note ?? "/\(name): nothing to edit")) }
      return SlashResult(notice: note, .prefill(words))
    case .send(let message, let display, let notice):
      return submit(message: message, display: display, notice: clean(notice), isSkill: false, invocation)
    case .skill(_, let message, let display):
      return submit(message: message ?? "", display: display, notice: nil, isSkill: true, invocation)
    }
  }

  private static func submit(
    message: String, display: String?, notice: String?, isSkill: Bool, _ invocation: SlashInvocation
  ) -> SlashResult {
    let words = message.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !words.isEmpty else {
      return SlashResult(notice: notice, .failure("/\(invocation.name): \(isSkill ? "the skill came back empty" : "empty message")"))
    }
    // The bubble shows the invocation the gateway projected, else what was typed: never the
    // expanded skill or the words a command composed. Matching the Mac's stored copy goes by what
    // is sent (`TranscriptItem.storedText(submitted:)`), not by this.
    let shown = clean(display) ?? invocation.typed
    return SlashResult(notice: notice, .submit(message: words, display: shown))
  }

  private static func clean(_ text: String?) -> String? {
    guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
    return text
  }

  static func describe(_ error: any Error) -> String {
    (error as? HermesError)?.localizedDescription ?? error.localizedDescription
  }
}

extension TranscriptItem {
  /// A command's answer, shown only on this phone under the command that asked for it.
  public static func slashNotice(_ text: String, command: String, timestamp: Double?) -> TranscriptItem {
    var item = TranscriptItem(kind: .system, text: text, timestamp: timestamp)
    item.isLocal = true
    item.command = command
    return item
  }

  /// The person's bubble for a turn being sent. A skill turn sends the expanded skill but shows
  /// the invocation (`shown`). What it is matched against the Mac's copy by is kept apart from
  /// that, in `sentText`: call `submitted(_:)` with the exact text once it is known.
  public static func outgoing(_ sent: String, shown: String?, timestamp: Double?) -> TranscriptItem {
    var item = TranscriptItem(kind: .user, text: shown ?? sent, timestamp: timestamp)
    item.isPending = true
    item.submitted(sent)
    return item
  }

  /// How the Mac's stored copy of `submitted` reads once the history is read back here: a skill
  /// turn as its invocation (`SkillInvocation`), anything else as sent. Matching a message sent
  /// from here against that copy goes by this, whatever its bubble shows.
  public static func storedText(submitted: String) -> String {
    SkillInvocation.text(submitted) ?? submitted
  }

  /// Records the exact text that went to the Mac (file references included), so the message is
  /// recognised in the Mac's history after a lost acknowledgement or a reload.
  public mutating func submitted(_ full: String) {
    sentText = Self.storedText(submitted: full)
  }
}
