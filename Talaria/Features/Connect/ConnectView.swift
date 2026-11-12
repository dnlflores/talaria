import HermesKit
import SwiftUI

/// First run and re-authentication: the Mac's address, then its password.
struct ConnectView: View {
  @Environment(AppModel.self) private var app
  @Environment(\.palette) private var palette
  @State private var address = ""
  @State private var password = ""
  @State private var isWorking = false
  @State private var error: String?
  @State private var editsAddress = false
  @FocusState private var focus: Field?

  private enum Field { case address, password }

  private var asksPassword: Bool { app.phase == .needsPassword && !editsAddress }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 28) {
        VStack(alignment: .leading, spacing: 10) {
          Wordmark(size: 30)
          Text(asksPassword ? "Sign in to your Mac." : "Your Hermes,\nin your pocket.")
            .font(AppFont.display)
            .foregroundStyle(palette.foreground)
          Text(asksPassword
            ? "Enter the password you set on the Mac with the hermesdash password command. It is traded for a session and never stored."
            : "Talaria talks to the Hermes agent running on your Mac through the hermesdash gate.")
            .font(AppFont.body)
            .foregroundStyle(palette.foregroundSecondary)
            .lineSpacing(3)
        }

        VStack(alignment: .leading, spacing: 0) {
          if asksPassword {
            HStack(spacing: 10) {
              Circle().fill(palette.success).frame(width: 7, height: 7)
              VStack(alignment: .leading, spacing: 2) {
                Text(app.endpoint?.displayName ?? "")
                  .font(AppFont.footnoteMedium)
                  .foregroundStyle(palette.foreground)
                  .lineLimit(1)
                  .truncationMode(.middle)
                Text("Reachable").font(AppFont.caption).foregroundStyle(palette.foregroundMuted)
              }
              Spacer(minLength: 8)
              Button("Change") {
                address = app.endpoint?.displayName ?? address
                editsAddress = true
                error = nil
                focus = .address
              }
              .font(AppFont.footnoteMedium)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
            Hairline().padding(.leading, 16)
            SecureField("Password", text: $password)
              .textContentType(.password)
              .submitLabel(.go)
              .focused($focus, equals: .password)
              .onSubmit(submit)
              .font(AppFont.body)
              .padding(.horizontal, 16)
              .frame(height: 52)
          } else {
            TextField("your-mac.example.ts.net:8443", text: $address)
              .textContentType(.URL)
              .keyboardType(.URL)
              .textInputAutocapitalization(.never)
              .autocorrectionDisabled()
              .submitLabel(.go)
              .focused($focus, equals: .address)
              .onSubmit(submit)
              .font(AppFont.body)
              .padding(.horizontal, 16)
              .frame(height: 52)
          }
        }
        .background(palette.groupedCard, in: RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous))

        if let error {
          Label(error, systemImage: "exclamationmark.triangle.fill")
            .font(AppFont.footnote)
            .foregroundStyle(palette.dangerForeground)
            .fixedSize(horizontal: false, vertical: true)
        }

        Button(action: submit) {
          HStack(spacing: 8) {
            if isWorking { ProgressView().tint(palette.prominentActionForeground) }
            Text(asksPassword ? "Sign in" : "Connect").font(AppFont.bodySemibold)
          }
          .frame(maxWidth: .infinity)
          .frame(height: 52)
          .foregroundStyle(palette.prominentActionForeground)
          .background(palette.prominentAction.opacity(canSubmit ? 1 : 0.35), in: Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!canSubmit)

        if !asksPassword {
          Text("Use the public address of hermesdash on your Mac, for example its Tailscale Funnel address on port 8443.")
            .font(AppFont.label)
            .foregroundStyle(palette.foregroundMuted)
            .lineSpacing(2)
        }
      }
      .padding(.horizontal, 24)
      .padding(.top, 72)
      .padding(.bottom, 32)
    }
    .scrollDismissesKeyboard(.interactively)
    .background(palette.screen.ignoresSafeArea())
    .onAppear {
      if address.isEmpty {
        address = app.preferences.serverAddress.isEmpty ? Preferences.bundledServerAddress : app.preferences.serverAddress
      }
      focus = asksPassword ? .password : .address
    }
    .onChange(of: app.phase) { _, phase in
      if phase == .needsPassword { focus = .password }
    }
  }

  private var canSubmit: Bool {
    if isWorking { return false }
    return asksPassword ? !password.isEmpty : !address.trimmingCharacters(in: .whitespaces).isEmpty
  }

  private func submit() {
    guard canSubmit else { return }
    isWorking = true
    error = nil
    let wantsPassword = asksPassword
    Task {
      defer { isWorking = false }
      do {
        if wantsPassword {
          try await app.signIn(password: password)
          password = ""
        } else {
          try await app.connect(to: address)
          editsAddress = false
        }
      } catch {
        self.error = error.localizedDescription
        if wantsPassword { password = "" }
      }
    }
  }
}
