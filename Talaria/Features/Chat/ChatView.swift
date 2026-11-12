import HermesKit
import SwiftUI

/// Resolves the model for a chat route once and keeps it for the life of the screen.
struct ChatRouteView: View {
  let profile: String
  let storedID: String
  @Environment(AppModel.self) private var app
  @Environment(\.palette) private var palette
  @State private var chat: ChatModel?

  var body: some View {
    Group {
      if let chat {
        ChatView(chat: chat)
      } else {
        palette.screen.ignoresSafeArea()
      }
    }
    .onAppear {
      if chat == nil { chat = app.chat(profile: profile, storedID: storedID) }
    }
  }
}

struct ChatView: View {
  @Bindable var chat: ChatModel
  @Environment(AppModel.self) private var app
  @Environment(\.palette) private var palette
  @Environment(\.dismiss) private var dismiss
  @State private var showsModels = false
  @State private var showsRename = false
  @State private var showsFiles = false
  @State private var newTitle = ""

  var body: some View {
    TranscriptView(chat: chat)
      .safeAreaInset(edge: .top, spacing: 0) {
        if let notice {
          ChatNotice(icon: notice.icon, text: notice.text)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
      }
      .safeAreaInset(edge: .bottom, spacing: 0) {
        if !chat.isReadOnly { ComposerView(chat: chat) }
      }
      .background(palette.screen.ignoresSafeArea())
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .principal) {
          VStack(spacing: 1) {
            Text(chat.title)
              .font(AppFont.sans(15, .semibold))
              .foregroundStyle(palette.foreground)
              .lineLimit(1)
            subtitleText
              .font(AppFont.micro)
              .foregroundStyle(palette.foregroundMuted)
              .lineLimit(1)
          }
          .frame(maxWidth: 260)
          .accessibilityElement(children: .combine)
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
          Button {
            showsModels = true
          } label: {
            Image(systemName: "cpu")
          }
          .disabled(chat.isReadOnly || chat.continuesAsNewVersion)
          .accessibilityLabel("Model and effort")
          moreMenu
        }
      }
      .sheet(isPresented: $showsFiles) {
        ChatFilesSheet(files: files, chat: chat)
      }
      .sheet(isPresented: $showsModels) {
        ModelPickerSheet(chat: chat)
          .presentationDetents([.large])
      }
      .alert("Rename chat", isPresented: $showsRename) {
        TextField("Title", text: $newTitle)
        Button("Cancel", role: .cancel) {}
        Button("Rename") {
          let title = newTitle
          Task { await chat.rename(to: title) }
        }
      }
      .onAppear {
        app.chatAppeared(chat)
        Task { await chat.open() }
      }
      .onDisappear { app.chatDisappeared(chat) }
  }

  /// "Working" leads the subtitle while a reply runs, so the state shows even when the transcript is scrolled away.
  private var subtitleText: Text {
    if chat.activity != nil {
      return Text("\(Text("Working").foregroundStyle(palette.primaryText)) · \(subtitle)")
    }
    return Text(subtitle)
  }

  private var files: [FileReference] { chat.files }

  private var subtitle: String {
    var parts = [app.title(forProfile: chat.profile)]
    if !chat.info.model.isEmpty { parts.append(Format.shortModel(chat.info.model)) }
    if !chat.info.reasoningEffort.isEmpty, chat.info.reasoningEffort != "none" { parts.append(chat.info.reasoningEffort) }
    return parts.joined(separator: " · ")
  }

  private var notice: (icon: String, text: String)? {
    if let owner = chat.owner {
      return ("macbook.and.iphone", "Open in \(owner.place). You can read along here. Sending continues it as a new version.")
    }
    if chat.isChannel {
      return ("number", "A \(chat.section.label) conversation. Sending here continues it as a Hermes chat that \(chat.section.label) does not see.")
    }
    if chat.isReadOnly {
      return ("lock", "Read-only. \(chat.loadError ?? "This chat could not be attached.")")
    }
    return nil
  }

  private var moreMenu: some View {
    let row = app.row(chat.storedID)
    let family = app.family(of: chat.storedID)
    return Menu {
      Button {
        newTitle = chat.title == "New chat" ? "" : chat.title
        showsRename = true
      } label: {
        Label("Rename", systemImage: "pencil")
      }
      Button {
        showsFiles = true
      } label: {
        let count = files.count
        Label(count == 0 ? "Files" : "Files (\(count))", systemImage: "doc.on.doc")
      }
      if let row {
        Button {
          app.setPinned(row, !row.pinned)
        } label: {
          Label(row.pinned ? "Unpin" : "Pin", systemImage: row.pinned ? "pin.slash" : "pin")
        }
        Button(role: .destructive) {
          app.archive(row)
          if app.usesSplitLayout { app.path = [] } else { dismiss() }
        } label: {
          Label("Archive", systemImage: "archivebox")
        }
      }
      if let family {
        Section("Versions") {
          ForEach(Array(family.members.enumerated()), id: \.element.id) { offset, member in
            Button {
              if member.id != chat.storedID { app.showVersion(profile: member.profile, storedID: member.id) }
            } label: {
              Label(
                "Version \(offset + 1)" + (app.owners[member.id] != nil ? " · on your Mac" : ""),
                systemImage: member.id == chat.storedID ? "checkmark" : "arrow.triangle.branch")
            }
          }
        }
      }
    } label: {
      Image(systemName: "ellipsis")
    }
    .accessibilityLabel("More")
  }
}

/// A calm strip under the title explaining why this chat behaves differently.
private struct ChatNotice: View {
  let icon: String
  let text: String
  @Environment(\.palette) private var palette

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Image(systemName: icon).font(.system(size: 12, weight: .semibold))
      Text(text)
        .font(AppFont.label)
        .lineSpacing(2)
        .fixedSize(horizontal: false, vertical: true)
    }
    .foregroundStyle(palette.warningForeground)
    .padding(.horizontal, 12)
    .padding(.vertical, 9)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(palette.warning, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    .overlay { RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(palette.warningBorder, lineWidth: 1) }
  }
}
