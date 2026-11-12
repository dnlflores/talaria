import HermesKit
import ImageIO
import SwiftUI
import UIKit

/// Pictures that live on the Mac, fetched through the gate (`/api/fs/download`) and kept in memory
/// at screen size. One fetch per picture however many views show it.
@MainActor
final class RemoteImageStore {
  static let shared = RemoteImageStore()

  enum Outcome {
    case image(UIImage)
    case missing(String)
  }

  private let cache = NSCache<NSString, UIImage>()
  private var failures: [String: String] = [:]
  private var loading: [String: Task<Outcome, Never>] = [:]

  private init() {
    cache.totalCostLimit = 96 * 1024 * 1024
  }

  private func key(_ path: String, _ profile: String) -> String { profile + "\u{1}" + path }

  /// What is known without asking the Mac.
  func cached(path: String, profile: String) -> Outcome? {
    let key = key(path, profile)
    if let image = cache.object(forKey: key as NSString) { return .image(image) }
    if let reason = failures[key] { return .missing(reason) }
    return nil
  }

  func load(path: String, profile: String, storedID: String?, client: HermesClient) async -> Outcome {
    if let known = cached(path: path, profile: profile) { return known }
    let key = key(path, profile)
    if let running = loading[key] { return await running.value }
    let task = Task<Outcome, Never> {
      do {
        let file = try await client.downloadFile(path: path, profile: profile, storedID: storedID)
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        guard let image = await RemoteImageStore.downsample(file, maxPixels: 1600) else {
          return .missing("Not a picture this phone can show")
        }
        return .image(image)
      } catch {
        let wrapped = error as? HermesError ?? .transport(error.localizedDescription)
        if case .http(let status, _) = wrapped, status == 404 { return .missing("No longer on your Mac") }
        return .missing(wrapped.localizedDescription)
      }
    }
    loading[key] = task
    let outcome = await task.value
    loading[key] = nil
    switch outcome {
    case .image(let image):
      let cost = Int(image.size.width * image.size.height * image.scale * image.scale * 4)
      cache.setObject(image, forKey: key as NSString, cost: cost)
    case .missing(let reason):
      // A picture that is gone stays gone; a dropped connection is worth another try later.
      if reason == "No longer on your Mac" || reason == "Not a picture this phone can show" { failures[key] = reason }
    }
    return outcome
  }

  /// Decodes straight to screen size, so a 4K screenshot never sits in memory at full size.
  nonisolated static func downsample(_ url: URL, maxPixels: Int) async -> UIImage? {
    await Task.detached(priority: .userInitiated) {
      guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
      else { return nil }
      let options: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceShouldCacheImmediately: true,
        kCGImageSourceThumbnailMaxPixelSize: maxPixels,
      ]
      guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
      return UIImage(cgImage: image)
    }.value
  }
}

/// One picture in a message: on the Mac (a path), or still only on this phone (just picked).
enum ChatPicture: Identifiable, Hashable {
  case remote(path: String)
  case local(id: UUID, image: UIImage, name: String)

  var id: String {
    switch self {
    case .remote(let path): return path
    case .local(let id, _, _): return id.uuidString
    }
  }

  var name: String {
    switch self {
    case .remote(let path): return FileReference(path: path, origin: .delivered).name
    case .local(_, _, let name): return name
    }
  }
}

/// Pictures in the transcript: one shows large at its own shape, several as square tiles that
/// wrap. Tapping one opens it full screen through Quick Look, with share.
struct PictureGallery: View {
  let pictures: [ChatPicture]
  let profile: String
  let storedID: String
  var alignment: HorizontalAlignment = .leading
  @Environment(\.horizontalSizeClass) private var sizeClass
  @State private var opened: FileReference?

  var body: some View {
    let regular = sizeClass == .regular
    Group {
      if pictures.count == 1, let picture = pictures.first {
        tile(picture, single: CGSize(width: regular ? 380 : 260, height: regular ? 420 : 300))
      } else {
        WrapLayout(spacing: 6, alignment: alignment) {
          ForEach(pictures) { picture in
            tile(picture, square: regular ? 150 : 112)
          }
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: Alignment(horizontal: alignment, vertical: .center))
    .sheet(item: $opened) { file in
      FilePreviewSheet(file: file, profile: profile, storedID: storedID)
    }
  }

  private func tile(_ picture: ChatPicture, single: CGSize? = nil, square: CGFloat? = nil) -> some View {
    Button {
      if case .remote(let path) = picture { opened = FileReference(path: path, origin: .delivered) }
    } label: {
      PictureView(picture: picture, profile: profile, storedID: storedID, single: single, square: square)
    }
    .buttonStyle(.plain)
    .accessibilityLabel(picture.name)
    .accessibilityHint(picture.isRemote ? "Opens the picture" : "")
    .accessibilityIdentifier("transcript.picture")
  }
}

extension ChatPicture {
  var isRemote: Bool {
    if case .remote = self { return true }
    return false
  }
}

/// A picture in a rounded frame, with a quiet placeholder while it loads and a plain word when
/// it cannot be shown.
private struct PictureView: View {
  let picture: ChatPicture
  let profile: String
  let storedID: String
  /// Largest box for a picture shown alone; it keeps its own shape inside.
  var single: CGSize?
  /// Side of a square tile when several show together.
  var square: CGFloat?
  @Environment(AppModel.self) private var app
  @Environment(\.palette) private var palette
  @State private var outcome: RemoteImageStore.Outcome?

  var body: some View {
    content
      .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
      .overlay { RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(palette.border, lineWidth: 0.5) }
      .task(id: picture.id) { await load() }
  }

  @ViewBuilder
  private var content: some View {
    switch resolved {
    case .image(let image):
      if let square {
        Image(uiImage: image).resizable().scaledToFill().frame(width: square, height: square)
      } else {
        let size = fitted(image.size)
        Image(uiImage: image).resizable().scaledToFill().frame(width: size.width, height: size.height)
      }
    case .missing(let reason):
      VStack(spacing: 6) {
        Image(systemName: "photo.badge.exclamationmark")
          .font(.system(size: 18, weight: .medium))
          .foregroundStyle(palette.iconMuted)
        Text(reason)
          .font(AppFont.caption)
          .foregroundStyle(palette.foregroundMuted)
          .multilineTextAlignment(.center)
          .lineLimit(2)
      }
      .padding(10)
      .frame(width: placeholderSize.width, height: placeholderSize.height)
      .background(palette.groupedCard)
    case nil:
      Image(systemName: "photo")
        .font(.system(size: 18, weight: .medium))
        .foregroundStyle(palette.iconMuted)
        .frame(width: placeholderSize.width, height: placeholderSize.height)
        .background(palette.groupedCard)
        .accessibilityLabel("Loading picture")
    }
  }

  private var resolved: RemoteImageStore.Outcome? {
    if case .local(_, let image, _) = picture { return .image(image) }
    return outcome
  }

  private var placeholderSize: CGSize {
    if let square { return CGSize(width: square, height: square) }
    let box = single ?? CGSize(width: 260, height: 300)
    return CGSize(width: box.width, height: (box.width * 0.62).rounded())
  }

  /// The picture's own shape, as large as the box allows, never upscaled past its pixels.
  private func fitted(_ size: CGSize) -> CGSize {
    let box = single ?? CGSize(width: 260, height: 300)
    guard size.width > 0, size.height > 0 else { return box }
    let scale = min(box.width / size.width, box.height / size.height, 1)
    let width = max((size.width * scale).rounded(), 64)
    let height = max((size.height * scale).rounded(), 48)
    return CGSize(width: width, height: height)
  }

  private func load() async {
    guard case .remote(let path) = picture else { return }
    if let known = RemoteImageStore.shared.cached(path: path, profile: profile) {
      outcome = known
      return
    }
    guard let client = app.client else { return }
    let result = await RemoteImageStore.shared.load(path: path, profile: profile, storedID: storedID, client: client)
    withAnimation(.easeInOut(duration: 0.2)) { outcome = result }
  }
}

/// Lays children out in rows, wrapping to the next row when one is full.
struct WrapLayout: Layout {
  var spacing: CGFloat = 6
  var alignment: HorizontalAlignment = .leading

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
    let width = rows.map(\.width).max() ?? 0
    let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0))
    return CGSize(width: width, height: height)
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    var y = bounds.minY
    for row in arrange(width: bounds.width, subviews: subviews) {
      var x: CGFloat
      switch alignment {
      case .trailing: x = bounds.maxX - row.width
      case .center: x = bounds.minX + (bounds.width - row.width) / 2
      default: x = bounds.minX
      }
      for index in row.indices {
        let size = subviews[index].sizeThatFits(.unspecified)
        subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
        x += size.width + spacing
      }
      y += row.height + spacing
    }
  }

  private struct Row {
    var indices: [Int] = []
    var width: CGFloat = 0
    var height: CGFloat = 0
  }

  private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
    var rows: [Row] = []
    var current = Row()
    for index in subviews.indices {
      let size = subviews[index].sizeThatFits(.unspecified)
      let needed = current.indices.isEmpty ? size.width : current.width + spacing + size.width
      if needed > width, !current.indices.isEmpty {
        rows.append(current)
        current = Row()
      }
      current.width = current.indices.isEmpty ? size.width : current.width + spacing + size.width
      current.height = max(current.height, size.height)
      current.indices.append(index)
    }
    if !current.indices.isEmpty { rows.append(current) }
    return rows
  }
}
