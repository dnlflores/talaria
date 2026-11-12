import HermesKit
import SwiftUI

/// A question from the agent that blocks its work: run this command? what is the password?
struct ServerPromptSheet: View {
  let request: ServerRequest
  @Environment(AppModel.self) private var app
  @Environment(\.palette) private var palette
  @State private var secret = ""
  @FocusState private var secretFocused: Bool

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 18) {
        HStack(spacing: 10) {
          Image(systemName: isApproval ? "hand.raised.fill" : "key.fill")
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(palette.warningForeground)
            .frame(width: 36, height: 36)
            .background(palette.warning, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
          VStack(alignment: .leading, spacing: 1) {
            Text(title).font(AppFont.headline).foregroundStyle(palette.foreground)
            Text(lead).font(AppFont.label).foregroundStyle(palette.foregroundMuted)
          }
        }

        if isApproval {
          approval
        } else {
          secretEntry
        }
      }
      .padding(20)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .background(palette.sheetSolid)
    .presentationDetents([.medium, .large])
    .presentationDragIndicator(.hidden)
  }

  private var isApproval: Bool { request.method == "approval" }
  private var bot: String { app.botTitle(forLive: request.sessionID) ?? "Hermes" }

  private var title: String {
    switch request.method {
    case "approval": return "Approval needed"
    case "sudo": return "Password needed"
    default: return "Secret needed"
    }
  }

  private var lead: String {
    switch request.method {
    case "approval": return "\(bot) wants to run this on your Mac."
    case "sudo": return "\(bot) needs your Mac's sudo password."
    default: return "\(bot) needs a value only you have."
    }
  }

  // MARK: Approval

  private var approval: some View {
    let params = request.params
    let command = params["command"].string ?? params["description"].string ?? params.text()
    let choices = (params["choices"].array ?? []).compactMap(\.string)
    return VStack(alignment: .leading, spacing: 14) {
      Text(command)
        .font(AppFont.mono(13))
        .lineSpacing(3)
        .foregroundStyle(palette.mdCodeText)
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(palette.mdCodeBg, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(palette.border, lineWidth: 1) }

      if let description = params["description"].string, params["command"].string != nil, !description.isEmpty {
        Text(description)
          .font(AppFont.footnote)
          .foregroundStyle(palette.foregroundSecondary)
          .fixedSize(horizontal: false, vertical: true)
      }

      VStack(spacing: 8) {
        ForEach(choices.isEmpty ? ["once", "session", "always", "deny"] : choices, id: \.self) { choice in
          Button {
            app.resolve(request, result: ["choice": .string(choice)])
          } label: {
            Text(ServerPromptSheet.label(for: choice))
              .font(AppFont.bodyMedium)
              .frame(maxWidth: .infinity)
              .frame(height: 48)
              .foregroundStyle(foreground(for: choice))
              .background(background(for: choice), in: Capsule())
              .overlay { if choice != "once" { Capsule().strokeBorder(border(for: choice), lineWidth: 1) } }
          }
          .buttonStyle(.plain)
        }
      }
    }
  }

  static func label(for choice: String) -> String {
    switch choice {
    case "once": return "Allow once"
    case "session": return "Allow for this session"
    case "always": return "Always allow"
    case "deny": return "Deny"
    default: return choice.capitalized
    }
  }

  private func foreground(for choice: String) -> Color {
    switch choice {
    case "once": return palette.prominentActionForeground
    case "deny": return palette.dangerForeground
    default: return palette.foreground
    }
  }

  private func background(for choice: String) -> Color {
    switch choice {
    case "once": return palette.prominentAction
    case "deny": return palette.danger
    default: return palette.secondary
    }
  }

  private func border(for choice: String) -> Color {
    choice == "deny" ? palette.dangerBorder : palette.secondaryBorder
  }

  // MARK: Sudo and secrets

  private var secretEntry: some View {
    let params = request.params
    let prompt = params["prompt"].string ?? params["description"].string ?? params["message"].string
    return VStack(alignment: .leading, spacing: 14) {
      if let prompt, !prompt.isEmpty {
        Text(prompt)
          .font(AppFont.footnote)
          .foregroundStyle(palette.foregroundSecondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      SecureField("Enter value", text: $secret)
        .textContentType(.password)
        .focused($secretFocused)
        .submitLabel(.send)
        .onSubmit(sendSecret)
        .font(AppFont.body)
        .padding(.horizontal, 14)
        .frame(height: 50)
        .background(palette.input, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(palette.inputBorder, lineWidth: 1) }
      Text("It goes straight to the agent on your Mac and is not kept on this phone.")
        .font(AppFont.caption)
        .foregroundStyle(palette.foregroundMuted)
      HStack(spacing: 10) {
        Button {
          app.resolve(request, result: nil)
        } label: {
          Text("Cancel")
            .font(AppFont.bodyMedium)
            .frame(maxWidth: .infinity)
            .frame(height: 48)
            .foregroundStyle(palette.foreground)
            .background(palette.secondary, in: Capsule())
            .overlay { Capsule().strokeBorder(palette.secondaryBorder, lineWidth: 1) }
        }
        Button(action: sendSecret) {
          Text("Send")
            .font(AppFont.bodyMedium)
            .frame(maxWidth: .infinity)
            .frame(height: 48)
            .foregroundStyle(palette.prominentActionForeground)
            .background(palette.prominentAction.opacity(secret.isEmpty ? 0.35 : 1), in: Capsule())
        }
        .disabled(secret.isEmpty)
      }
      .buttonStyle(.plain)
    }
    .onAppear { secretFocused = true }
  }

  private func sendSecret() {
    guard !secret.isEmpty else { return }
    let value = secret
    secret = ""
    app.resolve(request, result: ["value": .string(value)])
  }
}
