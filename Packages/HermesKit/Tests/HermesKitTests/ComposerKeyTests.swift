import Testing

@testable import HermesKit

/// A hardware keyboard in the composer: Return sends, Shift-Return adds a line.
struct ComposerKeyTests {
  @Test func returnSendsAndShiftOrOptionReturnAddsALine() {
    #expect(ComposerKey.action(usage: 0x28, shift: false, option: false, composing: false) == .send)
    #expect(ComposerKey.action(usage: 0x58, shift: false, option: false, composing: false) == .send)
    #expect(ComposerKey.action(usage: 0x28, shift: true, option: false, composing: false) == .newLine)
    #expect(ComposerKey.action(usage: 0x28, shift: false, option: true, composing: false) == .newLine)
  }

  @Test func otherKeysAndComposingTextAreLeftAlone() {
    // "z", Tab, Escape.
    for usage in [0x1D, 0x2B, 0x29] {
      #expect(ComposerKey.action(usage: usage, shift: false, option: false, composing: false) == .pass)
    }
    // Return while Japanese input is composing commits the text, as it always has.
    #expect(ComposerKey.action(usage: 0x28, shift: false, option: false, composing: true) == .pass)
  }
}
