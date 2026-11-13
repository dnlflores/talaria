import ActivityKit
import HermesKit
import SwiftUI
import UserNotifications

/// Settings > Notifications: what iOS allows, what the Mac can send, and which chats notify.
struct NotificationSettings: View {
  @Environment(AppModel.self) private var app
  @Environment(\.palette) private var palette
  @Environment(\.openURL) private var openURL
  @State private var push = PushCenter.shared
  @State private var activitiesEnabled = ActivityAuthorizationInfo().areActivitiesEnabled

  var body: some View {
    @Bindable var preferences = app.preferences
    VStack(alignment: .leading, spacing: 8) {
      GroupedSection("Notifications") {
        ValueRow("This \(device)", permissionText, color: permissionColor)
        if push.authorization == .notDetermined {
          Hairline().padding(.leading, 16)
          ActionRow("Allow notifications", systemImage: "bell.badge") {
            Task { await push.requestAuthorization() }
          }
        } else if push.authorization == .denied {
          Hairline().padding(.leading, 16)
          ActionRow("Turn on in iOS Settings", systemImage: "gear") {
            if let url = URL(string: UIApplication.openNotificationSettingsURLString) { openURL(url) }
          }
        }
        Hairline().padding(.leading, 16)
        ValueRow("Your Mac", macText, color: macColor)
          .accessibilityIdentifier("push.mac")
        Hairline().padding(.leading, 16)
        ToggleRow(
          title: "When a reply finishes", detail: "And when a bot asks you something.", isOn: $preferences.notifyFinished
        )
        .accessibilityIdentifier("push.alerts")
        Hairline().padding(.leading, 16)
        ToggleRow(
          title: "Live Activities",
          detail: activitiesEnabled
            ? "A running reply on the Lock Screen and in the Dynamic Island." : "Turned off for Talaria in iOS Settings.",
          isOn: $preferences.liveActivities
        )
        .accessibilityIdentifier("push.activities")
        Hairline().padding(.leading, 16)
        Picker("Chats", selection: $preferences.notifyScope) {
          Text("All chats").tag(PushRegistration.Scope.all.rawValue)
          Text("Sent from this phone").tag(PushRegistration.Scope.phone.rawValue)
        }
        .pickerStyle(.segmented)
        .padding(12)
        .accessibilityIdentifier("push.scope")
        Hairline().padding(.leading, 16)
        ActionRow("Send a test notification", systemImage: "paperplane", isWorking: push.isTesting) {
          Task { await push.sendTest() }
        }
        .disabled(push.macState != .ready)
        .opacity(push.macState == .ready ? 1 : 0.45)
      }
      if let note = footnote {
        Text(note)
          .font(AppFont.label)
          .foregroundStyle(palette.foregroundMuted)
          .lineSpacing(2)
          .padding(.horizontal, 4)
          .accessibilityIdentifier("push.note")
      }
    }
    .onChange(of: preferences.notifyFinished) { _, on in
      if on, push.authorization == .notDetermined { Task { await push.requestAuthorization() } }
      push.settingsChanged()
    }
    .onChange(of: preferences.liveActivities) { push.settingsChanged() }
    .onChange(of: preferences.notifyScope) { push.settingsChanged() }
    .task {
      await push.refreshAuthorization()
      activitiesEnabled = ActivityAuthorizationInfo().areActivitiesEnabled
    }
  }

  private var device: String { UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone" }

  private var permissionText: String {
    switch push.authorization {
    case .authorized, .provisional, .ephemeral: return "Allowed"
    case .denied: return "Off in iOS Settings"
    case .notDetermined: return "Not asked yet"
    @unknown default: return "Unknown"
    }
  }

  private var permissionColor: Color? {
    switch push.authorization {
    case .authorized, .provisional, .ephemeral: return palette.success
    case .denied: return palette.warningForeground
    default: return nil
    }
  }

  private var macText: String {
    switch push.macState {
    case .unknown: return "Checking"
    case .ready: return "Ready"
    case .needsKey: return "Needs an APNs key"
    case .notInstalled: return "Plugin not installed"
    case .failed: return "Not reachable"
    }
  }

  private var macColor: Color? {
    switch push.macState {
    case .ready: return palette.success
    case .needsKey, .notInstalled, .failed: return palette.warningForeground
    case .unknown: return nil
    }
  }

  private var footnote: String? {
    if let result = push.testResult { return result }
    switch push.macState {
    case .notInstalled:
      return "Your Mac sends these. Install the talaria-push plugin there (scripts/install-push-plugin.sh in the Talaria repository) and enable it."
    case .needsKey:
      return "Your Mac knows this \(device) but has no APNs key to send with yet. Put the AuthKey .p8 file from your Apple developer account in ~/.hermes/plugin-data/talaria-push on the Mac."
    case .failed(let message):
      return message
    default:
      return nil
    }
  }
}

/// A switch with a title and a line under it.
private struct ToggleRow: View {
  let title: String
  let detail: String
  @Binding var isOn: Bool
  @Environment(\.palette) private var palette

  var body: some View {
    Toggle(isOn: $isOn) {
      VStack(alignment: .leading, spacing: 2) {
        Text(title).font(AppFont.body).foregroundStyle(palette.foreground)
        Text(detail).font(AppFont.label).foregroundStyle(palette.foregroundMuted)
      }
    }
    .tint(palette.primary)
    .padding(.horizontal, 16)
    .padding(.vertical, 11)
  }
}
