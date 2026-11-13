import FoundationModels
import HermesKit
import Observation
import SwiftUI

/// Short titles for memories, which Hermes keeps as untitled paragraphs. Apple's on-device model
/// names each one ("Staging database", "Code review style"); the text never leaves the
/// phone. Titles are kept per memory text, so a memory is named once. Without the model (Apple
/// Intelligence off, an older device) a memory is titled by its own first words.
@MainActor @Observable
final class MemoryTitles {
  private(set) var titles: [String: String]
  private(set) var isNaming = false
  @ObservationIgnored private let defaults: UserDefaults
  private static let key = "memory.titles"

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    titles = defaults.dictionary(forKey: Self.key) as? [String: String] ?? [:]
  }

  func title(for note: MemoryNote) -> String {
    titles[note.titleKey] ?? MemoryTitle.fallback(note.text)
  }

  /// Names the memories that have no title yet, one at a time, publishing each as it lands.
  func name(_ notes: [MemoryNote]) async {
    let missing = notes.filter { titles[$0.titleKey] == nil && !$0.text.isEmpty }
    guard !missing.isEmpty, !isNaming, Self.modelIsReady else { return }
    isNaming = true
    defer { isNaming = false }
    for note in missing {
      if Task.isCancelled { break }
      guard let title = await Self.generate(note.text) else { continue }
      titles[note.titleKey] = title
      save(keeping: Set(notes.map(\.titleKey)))
    }
  }

  private func save(keeping current: Set<String>) {
    // Titles of memories since rewritten or removed are dropped once the list grows long.
    if titles.count > 400 { titles = titles.filter { current.contains($0.key) } }
    defaults.set(titles, forKey: Self.key)
  }

  private static var modelIsReady: Bool {
    if case .available = SystemLanguageModel.default.availability { return true }
    return false
  }

  private nonisolated static let instructions = """
    You label notes that an assistant keeps about the person it works for and their work, \
    the way a person labels a folder. A label is two to four words naming the note's subject, \
    not what happened. Start with a capital letter and keep acronyms in capitals. \
    Never use the person's name.

    Examples:
    Note: Prefers dark mode everywhere and turns off notification sounds.
    Label: Display and sound preferences
    Note: The staging database is on db-staging:5432; run migrations with make migrate.
    Label: Staging database
    Note: Wants code reviews to point out risky changes first, then style.
    Label: Code review style
    """

  /// One title from the on-device model, greedy so the same text gets the same title on every
  /// device. Nil when the model declines (its guardrails) or answers with something unusable.
  private nonisolated static func generate(_ text: String) async -> String? {
    let session = LanguageModelSession(instructions: instructions)
    do {
      let response = try await session.respond(
        to: "Label this note:\n\(text.prefix(1200))", generating: MemoryLabel.self,
        options: GenerationOptions(sampling: .greedy))
      return MemoryTitle.clean(response.content.title)
    } catch {
      return nil
    }
  }
}

@Generable
struct MemoryLabel {
  @Guide(description: "A label of two to four words saying what the note is about, in sentence case")
  var title: String
}
