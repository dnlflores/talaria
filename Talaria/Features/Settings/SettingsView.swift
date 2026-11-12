import HermesKit
import SwiftUI

struct SettingsView: View {
  @Environment(AppModel.self) private var app
  @Environment(\.palette) private var palette
  @Environment(\.colorScheme) private var colorScheme
  @State private var confirmsForget = false

  var body: some View {
    @Bindable var preferences = app.preferences
    ScrollView {
      VStack(alignment: .leading, spacing: 26) {
        group("Your Mac") {
          HStack(spacing: 10) {
            Circle().fill(statusColor).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
              Text(app.endpoint?.displayName ?? "Not set")
                .font(AppFont.bodyMedium)
                .foregroundStyle(palette.foreground)
                .lineLimit(1)
                .truncationMode(.middle)
              Text(statusText).font(AppFont.label).foregroundStyle(palette.foregroundMuted)
            }
            Spacer(minLength: 0)
          }
          .padding(.horizontal, 16)
          .padding(.vertical, 13)
          if !app.hermesVersion.isEmpty {
            Hairline().padding(.leading, 16)
            valueRow("Hermes", app.hermesVersion)
          }
          Hairline().padding(.leading, 16)
          valueRow("Bots", "\(app.profiles.count)")
          Hairline().padding(.leading, 16)
          actionRow("Sign out", systemImage: "rectangle.portrait.and.arrow.right") {
            Task { await app.signOut() }
          }
          Hairline().padding(.leading, 16)
          actionRow("Use a different Mac", systemImage: "arrow.left.arrow.right", isDestructive: true) {
            confirmsForget = true
          }
        }

        group("Appearance") {
          Picker("Appearance", selection: $preferences.appearance) {
            ForEach(AppearanceMode.allCases) { mode in Text(mode.name).tag(mode) }
          }
          .pickerStyle(.segmented)
          .padding(12)
          Hairline().padding(.leading, 16)
          LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
            ForEach(ThemeFamily.allCases) { family in
              ThemeSwatch(
                family: family, scheme: preferences.appearance.colorScheme ?? colorScheme,
                isSelected: preferences.themeFamily == family
              ) {
                withAnimation(.easeInOut(duration: 0.2)) { preferences.themeFamily = family }
              }
            }
          }
          .padding(12)
        }

        group("About") {
          valueRow("Version", Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")
          Hairline().padding(.leading, 16)
          Text("Talaria is a personal client for Hermes Agent by Nous Research. Its colors and layout follow T3 Code's mobile app (MIT). Type is DM Sans (SIL Open Font License).")
            .font(AppFont.label)
            .foregroundStyle(palette.foregroundMuted)
            .lineSpacing(2)
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
        }
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 12)
    }
    .background(palette.screen.ignoresSafeArea())
    .navigationTitle("Settings")
    .navigationBarTitleDisplayMode(.inline)
    .confirmationDialog("Use a different Mac?", isPresented: $confirmsForget, titleVisibility: .visible) {
      Button("Forget this Mac", role: .destructive) {
        Task { await app.forgetServer() }
      }
    } message: {
      Text("This signs you out and clears the saved address. Chats stay on the Mac.")
    }
  }

  private var statusText: String {
    switch app.connection {
    case .open: return "Connected"
    case .connecting, .idle: return "Connecting"
    case .closed: return "Offline, retrying"
    case .unauthorized: return "Signed out"
    }
  }

  private var statusColor: Color {
    switch app.connection {
    case .open: return palette.success
    case .connecting, .idle: return palette.foregroundMuted
    case .closed: return palette.warningForeground
    case .unauthorized: return palette.dangerForeground
    }
  }

  private func group(_ title: String, @ViewBuilder content: () -> some View) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(title.uppercased())
        .font(AppFont.sans(11, .semibold))
        .kerning(0.6)
        .foregroundStyle(palette.foregroundMuted)
        .padding(.leading, 4)
      VStack(alignment: .leading, spacing: 0) { content() }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.groupedCard, in: RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous))
    }
  }

  private func valueRow(_ label: String, _ value: String) -> some View {
    HStack {
      Text(label).font(AppFont.body).foregroundStyle(palette.foreground)
      Spacer(minLength: 12)
      Text(value).font(AppFont.footnote).foregroundStyle(palette.foregroundMuted).lineLimit(1)
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 13)
  }

  private func actionRow(_ label: String, systemImage: String, isDestructive: Bool = false, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      HStack {
        Text(label).font(AppFont.body)
        Spacer(minLength: 12)
        Image(systemName: systemImage).font(.system(size: 14, weight: .medium))
      }
      .foregroundStyle(isDestructive ? palette.dangerForeground : palette.primaryText)
      .padding(.horizontal, 16)
      .padding(.vertical, 13)
      .contentShape(Rectangle())
    }
    .buttonStyle(RowButtonStyle())
  }
}

/// A miniature of the chat screen in one palette.
private struct ThemeSwatch: View {
  let family: ThemeFamily
  let scheme: ColorScheme
  let isSelected: Bool
  let action: () -> Void
  @Environment(\.palette) private var palette

  var body: some View {
    let preview = family.palette(for: scheme)
    Button(action: action) {
      VStack(spacing: 7) {
        VStack(alignment: .leading, spacing: 5) {
          Capsule().fill(preview.userBubble).frame(width: 34, height: 9).frame(maxWidth: .infinity, alignment: .trailing)
          Capsule().fill(preview.foreground.opacity(0.75)).frame(width: 44, height: 5)
          Capsule().fill(preview.foregroundMuted.opacity(0.6)).frame(width: 30, height: 5)
          HStack(spacing: 4) {
            Capsule().fill(preview.composerSurface).frame(height: 10)
            Circle().fill(preview.primary).frame(width: 10, height: 10)
          }
        }
        .padding(9)
        .frame(height: 68)
        .background(preview.screen, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay {
          RoundedRectangle(cornerRadius: 13, style: .continuous)
            .strokeBorder(isSelected ? palette.primary : preview.border, lineWidth: isSelected ? 2 : 1)
        }
        Text(family.name)
          .font(AppFont.sans(12, isSelected ? .semibold : .regular))
          .foregroundStyle(isSelected ? palette.foreground : palette.foregroundMuted)
      }
    }
    .buttonStyle(.plain)
    .accessibilityLabel(family.name)
    .accessibilityAddTraits(isSelected ? .isSelected : [])
  }
}
