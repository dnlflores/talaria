import HermesKit
import SwiftUI
import UIKit

/// The composer's text: a `UITextView`, so a hardware keyboard's Return can send.
///
/// SwiftUI's multi-line `TextField` swallows a hardware Return on iOS 27: no new line, no
/// `onSubmit`, no `onKeyPress`. A text view sees every key in `pressesBegan` before text input
/// does, and the on-screen keyboard never goes through it, so its Return still types a new line.
struct ComposerInput: UIViewRepresentable {
  @Binding var text: String
  var placeholder: String
  var maxLines: Int = 8
  /// Return on a hardware keyboard (no Shift or Option).
  var onReturn: () -> Void
  @Environment(\.palette) private var palette

  func makeCoordinator() -> Coordinator { Coordinator(self) }

  func makeUIView(context: Context) -> ReturnKeyTextView {
    let view = ReturnKeyTextView()
    view.delegate = context.coordinator
    view.backgroundColor = .clear
    view.textContainerInset = .zero
    view.textContainer.lineFragmentPadding = 0
    view.isScrollEnabled = false
    view.font = Self.font
    view.adjustsFontForContentSizeCategory = true
    view.accessibilityIdentifier = "composer.input"
    view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    view.setContentHuggingPriority(.defaultLow, for: .horizontal)
    view.onReturn = { [weak coordinator = context.coordinator] in coordinator?.parent.onReturn() }
    return view
  }

  func updateUIView(_ view: ReturnKeyTextView, context: Context) {
    context.coordinator.parent = self
    if view.text != text {
      view.text = text
      view.invalidateIntrinsicContentSize()
    }
    view.textColor = UIColor(palette.foreground)
    view.tintColor = UIColor(palette.primary)
    view.accessibilityLabel = placeholder
  }

  func sizeThatFits(_ proposal: ProposedViewSize, uiView: ReturnKeyTextView, context: Context) -> CGSize? {
    guard let width = proposal.width, width.isFinite, width > 0 else { return nil }
    let fitting = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
    let limit = (uiView.font?.lineHeight ?? 21) * CGFloat(maxLines)
    let scrolls = fitting.height > limit
    if uiView.isScrollEnabled != scrolls { uiView.isScrollEnabled = scrolls }
    return CGSize(width: width, height: min(fitting.height, limit))
  }

  /// DM Sans 17, scaled with Dynamic Type.
  static var font: UIFont {
    let base = UIFont(name: "DMSans-Regular", size: 17) ?? .systemFont(ofSize: 17)
    return UIFontMetrics(forTextStyle: .body).scaledFont(for: base)
  }

  final class Coordinator: NSObject, UITextViewDelegate {
    var parent: ComposerInput

    init(_ parent: ComposerInput) {
      self.parent = parent
    }

    func textViewDidChange(_ textView: UITextView) {
      if parent.text != textView.text { parent.text = textView.text }
      textView.invalidateIntrinsicContentSize()
    }
  }
}

/// A text view that turns a hardware Return into "send" and Shift- or Option-Return into a new
/// line (`ComposerKey`). Return while composing marked text (Japanese, Chinese input) still
/// commits the text.
final class ReturnKeyTextView: UITextView {
  var onReturn: (() -> Void)?
  /// Presses whose begin was handled here: their end must not reach UIKit either.
  private var handled: Set<UIPress> = []

  override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
    guard presses.count == 1, let press = presses.first, let key = press.key else {
      super.pressesBegan(presses, with: event)
      return
    }
    let action = ComposerKey.action(
      usage: key.keyCode.rawValue, shift: key.modifierFlags.contains(.shift),
      option: key.modifierFlags.contains(.alternate), composing: markedTextRange != nil)
    switch action {
    case .pass:
      super.pressesBegan(presses, with: event)
    case .newLine:
      handled.insert(press)
      insertText("\n")
    case .send:
      handled.insert(press)
      onReturn?()
    }
  }

  override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
    let mine = presses.intersection(handled)
    handled.subtract(mine)
    let rest = presses.subtracting(mine)
    if !rest.isEmpty { super.pressesEnded(rest, with: event) }
  }

  override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
    let mine = presses.intersection(handled)
    handled.subtract(mine)
    let rest = presses.subtracting(mine)
    if !rest.isEmpty { super.pressesCancelled(rest, with: event) }
  }
}
