import Foundation

/// What a key on a hardware keyboard does in the composer. UIKit-free (HID usage codes and
/// plain flags) so it is tested here; `ReturnKeyTextView` in the app asks it for every press.
public enum ComposerKey: Equatable, Sendable {
  /// Send the draft.
  case send
  /// Add a line break where the cursor is.
  case newLine
  /// Not ours: the text view handles it as usual.
  case pass

  /// HID usages: Return and the keypad's Enter.
  static let returnUsage = 0x28
  static let keypadEnterUsage = 0x58

  /// Return sends; Shift- or Option-Return adds a line; Command-Return and Control-Return send
  /// too. While an input method is composing (marked text), Return commits that text instead.
  public static func action(usage: Int, shift: Bool, option: Bool, composing: Bool) -> ComposerKey {
    guard usage == returnUsage || usage == keypadEnterUsage, !composing else { return .pass }
    return shift || option ? .newLine : .send
  }
}
