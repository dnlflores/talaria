import Foundation

/// A file on the Mac that a chat made, changed or handed over.
public struct FileReference: Identifiable, Sendable, Hashable {
  /// How the file came up in the chat, strongest first.
  public enum Origin: Int, Sendable, Hashable, Comparable {
    /// The agent wrote it with a file tool.
    case written = 3
    /// The agent edited it in place.
    case edited = 2
    /// The answer delivered it explicitly (`MEDIA:` line) or a tool reported producing it.
    case delivered = 1
    /// The answer mentioned its path.
    case mentioned = 0

    public static func < (a: Origin, b: Origin) -> Bool { a.rawValue < b.rawValue }
  }

  public enum Kind: Sendable, Hashable {
    case image, pdf, audio, video, text, code, table, archive, document, other
  }

  public var id: String { path }
  /// As the chat gave it: usually absolute, sometimes relative to the chat's working folder.
  public let path: String
  public var origin: Origin
  /// When the chat last touched it, seconds since 1970.
  public var timestamp: Double?

  public init(path: String, origin: Origin, timestamp: Double? = nil) {
    self.path = path
    self.origin = origin
    self.timestamp = timestamp
  }

  public var name: String {
    let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
    return trimmed.split(separator: "/").last.map(String.init) ?? trimmed
  }

  /// The folder part of the path, empty for a bare name.
  public var folder: String {
    guard let slash = path.lastIndex(of: "/") else { return "" }
    return String(path[..<slash])
  }

  public var fileExtension: String {
    guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return "" }
    return name[name.index(after: dot)...].lowercased()
  }

  public var kind: Kind { FileReference.kind(forExtension: fileExtension) }

  public static func kind(forExtension ext: String) -> Kind {
    switch ext {
    case "png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "bmp", "tif", "tiff": return .image
    case "pdf": return .pdf
    case "mp3", "m4a", "wav", "aac", "flac", "ogg", "opus", "aiff": return .audio
    case "mp4", "mov", "m4v", "webm", "mkv", "avi": return .video
    case "txt", "md", "markdown", "log", "rtf", "srt", "vtt": return .text
    case "csv", "tsv", "xlsx", "xls", "numbers": return .table
    case "zip", "tar", "gz", "tgz", "bz2", "xz", "7z", "dmg": return .archive
    case "docx", "doc", "pptx", "ppt", "key", "pages", "epub": return .document
    case "json", "yaml", "yml", "toml", "xml", "html", "htm", "css", "scss", "js", "mjs", "cjs", "ts", "tsx",
      "jsx", "py", "rb", "go", "rs", "swift", "kt", "java", "c", "h", "cc", "cpp", "hpp", "m", "mm", "sh",
      "zsh", "bash", "fish", "sql", "ini", "cfg", "conf", "svg", "lua", "php", "pl", "r", "dart", "vue",
      "svelte", "graphql", "proto", "gradle", "make", "dockerfile", "tf", "ipynb", "plist", "xcconfig":
      return .code
    default: return .other
    }
  }

  /// Text the Mac can show as-is (the preview reads it as text rather than downloading it).
  public var isTextual: Bool { kind == .text || kind == .code || ["csv", "tsv"].contains(fileExtension) }
}

/// Finds the files a stretch of transcript produced. The rules follow the Hermes desktop
/// app's Artifacts page, narrowed to what a person would want to open from a phone:
/// - `write_file` and `patch` calls name the files they wrote or edited.
/// - Tool results that report a produced file under a telling key (`output_path`,
///   `saved_to`, `files_modified`, ...).
/// - `MEDIA:` lines in an answer deliver a file on purpose, whatever its type.
/// - Absolute paths in an answer that end in a known file extension. Code blocks are
///   skipped: a path inside a shown command is rarely a result.
public enum FileExtraction {
  public static func files(in items: [TranscriptItem]) -> [FileReference] {
    var order: [String] = []
    var found: [String: FileReference] = [:]

    func add(_ raw: String, _ origin: FileReference.Origin, _ timestamp: Double?) {
      guard let path = normalize(raw) else { return }
      if var existing = found[path] {
        existing.origin = max(existing.origin, origin)
        if let timestamp { existing.timestamp = max(existing.timestamp ?? 0, timestamp) }
        found[path] = existing
      } else {
        order.append(path)
        found[path] = FileReference(path: path, origin: origin, timestamp: timestamp)
      }
    }

    for item in items {
      switch item.kind {
      case .tool:
        guard let tool = item.tool else { continue }
        for (path, origin) in toolFiles(tool) { add(path, origin, item.timestamp) }
      case .assistant:
        for (path, explicit) in textFiles(item.text) { add(path, explicit ? .delivered : .mentioned, item.timestamp) }
      case .user, .system:
        continue
      }
    }
    return mergingHomeShorthand(order.compactMap { found[$0] })
  }

  /// An answer without its `MEDIA:` lines, which the app shows as file chips under it instead.
  /// Lines inside code blocks stay: there the tag is being shown, not used.
  public static func hidingMediaLines(_ text: String) -> String {
    guard text.contains("MEDIA:") else { return text }
    var inFence = false
    var kept: [Substring] = []
    for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") { inFence.toggle() }
      if !inFence, trimmed.wholeMatch(of: /MEDIA:\s*(`[^`]+`|"[^"]+"|\S+)/) != nil { continue }
      kept.append(line)
    }
    return kept.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// One file is often named two ways in a turn:
  /// - an answer says `~/x/y.md` where a tool reported `/Users/me/x/y.md`;
  /// - an answer says `/tmp/a.txt` where a tool resolved it to `/private/tmp/a.txt`
  ///   (on macOS `/tmp`, `/var` and `/etc` are links into `/private`).
  /// When both appear, keep the path the tool reported once, with the stronger origin.
  static func mergingHomeShorthand(_ files: [FileReference]) -> [FileReference] {
    var out = files
    for (index, file) in files.enumerated() {
      guard let target = out.indices.first(where: { $0 != index && !out[$0].path.isEmpty && isAlias(file.path, of: out[$0].path) })
      else { continue }
      out[target].origin = max(out[target].origin, file.origin)
      if let stamp = file.timestamp { out[target].timestamp = max(out[target].timestamp ?? 0, stamp) }
      out[index] = FileReference(path: "", origin: .mentioned)
    }
    return out.filter { !$0.path.isEmpty }
  }

  /// Whether `short` names the same file as `full` in a shorter or unresolved form.
  static func isAlias(_ short: String, of full: String) -> Bool {
    if short.hasPrefix("~/") {
      let rest = String(short.dropFirst(1))
      guard full.hasSuffix(rest), let home = full.firstMatch(of: /^\/(?:Users|home)\/[^\/]+/) else { return false }
      return full == String(home.0) + rest
    }
    for root in ["/tmp/", "/var/", "/etc/"] where short.hasPrefix(root) {
      return full == "/private" + short
    }
    return false
  }

  // MARK: Tools

  private static let readOnlyTools: Set<String> = [
    "read_file", "search_files", "web_search", "web_extract", "vision_analyze", "clarify", "skill_view",
    "skills_list", "session_search", "memory", "todo", "todo_list",
  ]

  /// Keys whose value names a produced file in any tool's result.
  private static let strongKeys: Set<String> = [
    "files_modified", "files_created", "files_written", "file_created", "file_written", "output_path",
    "output_file", "output_url", "saved_to", "saved_path", "screenshot_path", "generated_file", "generated_path",
    "artifact_path", "artifact_file", "media_path", "audio_path", "image_path", "video_path", "result_path",
    "result_file", "export_path", "download_path",
  ]

  /// Keys that name a produced file only when the tool itself makes files.
  private static let producerKeys: Set<String> = ["path", "file_path", "file", "local_path", "filename"]

  static func toolFiles(_ tool: ToolCall) -> [(String, FileReference.Origin)] {
    let name = tool.name.lowercased()
    if readOnlyTools.contains(name) || tool.isError { return [] }
    var out: [(String, FileReference.Origin)] = []
    let args = tool.args.parsedIfJSONString
    let result = (try? JSONValue.parse(tool.result.trimmingCharacters(in: .whitespacesAndNewlines))) ?? .null

    switch name {
    case "write_file":
      let resolved = result["resolved_path"].string ?? ""
      if let path = args["path"].string ?? args["file_path"].string, !path.isEmpty {
        out.append((resolved.isEmpty ? path : resolved, .written))
      }
      return out
    case "patch":
      if let path = args["path"].string ?? args["file_path"].string, !path.isEmpty { out.append((path, .edited)) }
      if let patch = args["patch"].string {
        for match in patch.matches(of: /(?m)^\*\*\* (Add|Update) File: (.+)$/) {
          out.append((String(match.2).trimmingCharacters(in: .whitespaces), match.1 == "Add" ? .written : .edited))
        }
      }
      for path in (result["files_modified"].array ?? []).compactMap(\.string) where !out.contains(where: { $0.0 == path }) {
        out.append((path, .edited))
      }
      return out
    default:
      break
    }

    let producer = name.contains(/(?:^|_)(?:creat(?:e|ion)|download|export|generat(?:e|ion)|render|save|speech|tts|write|screenshot|image|record)(?:_|$)/)
      || name == "text_to_speech"
    collect(result, producer: producer) { out.append(($0, .delivered)) }
    return out
  }

  private static func collect(_ value: JSONValue, producer: Bool, key: String = "", _ emit: (String) -> Void) {
    switch value {
    case .string(let text):
      let lowered = key.lowercased()
      guard strongKeys.contains(lowered) || (producer && producerKeys.contains(lowered)) else { return }
      if looksLikeFilePath(text, requireExtension: false) { emit(text) }
    case .array(let list):
      for entry in list { collect(entry, producer: producer, key: key, emit) }
    case .object(let fields):
      for (child, entry) in fields { collect(entry, producer: producer, key: child, emit) }
    default:
      return
    }
  }

  // MARK: Text

  /// Paths in an answer, each with whether it was delivered on purpose.
  static func textFiles(_ text: String) -> [(String, Bool)] {
    guard !text.isEmpty else { return [] }
    var out: [(String, Bool)] = []
    var inFence = false
    for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
        inFence.toggle()
        continue
      }
      for match in line.matches(of: /MEDIA:\s*(`[^`]+`|"[^"]+"|\S+)/) {
        out.append((unquote(String(match.1)), true))
      }
      if inFence { continue }
      let withoutMedia = line.replacing(/MEDIA:\s*(`[^`]+`|"[^"]+"|\S+)/, with: "")
      for match in withoutMedia.matches(of: /(?:^|[\s(\[`"'<])((?:~\/|\/)[^\s`"'<>()\[\]]*\.[A-Za-z0-9]{1,8})(?=$|[\s)\]`"'>,;:!?]|\.(?:\s|$))/) {
        let path = String(match.1)
        if looksLikeFilePath(path, requireExtension: true) { out.append((path, false)) }
      }
    }
    return out
  }

  private static func unquote(_ value: String) -> String {
    var text = value.trimmingCharacters(in: .whitespaces)
    if let first = text.first, let last = text.last, text.count >= 2, first == last, "`\"'".contains(first) {
      text = String(text.dropFirst().dropLast())
    }
    return text
  }

  static func looksLikeFilePath(_ raw: String, requireExtension: Bool) -> Bool {
    let path = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !path.isEmpty, path.count < 1024, !path.contains("\n") else { return false }
    if path.contains("://") { return false }
    guard path.hasPrefix("/") || path.hasPrefix("~/") || (!requireExtension && !path.hasPrefix("-")) else { return false }
    if path.hasSuffix("/") { return false }
    let lowered = path.lowercased()
    // Package-manager traffic is not something the chat made.
    if lowered.contains("/.cache/pip/") || lowered.contains("/library/caches/pip/") || lowered.hasSuffix(".whl") { return false }
    if lowered.contains("/node_modules/") || lowered.contains("/site-packages/") || lowered.contains("/.git/") { return false }
    let reference = FileReference(path: path, origin: .mentioned)
    if requireExtension {
      let ext = reference.fileExtension
      return !ext.isEmpty && (reference.kind != .other || knownExtensions.contains(ext))
    }
    return true
  }

  /// Extensions that read as a file even though the preview has no special kind for them.
  private static let knownExtensions: Set<String> = ["bin", "dat", "ics", "vcf", "ttf", "otf", "woff", "woff2", "pkl", "parquet", "sqlite", "db"]

  /// Trims what prose wraps around a path and drops the obviously not-a-file.
  static func normalize(_ raw: String) -> String? {
    var path = unquote(raw).trimmingCharacters(in: .whitespacesAndNewlines)
    while let last = path.last, ".,;:)]*`'\"".contains(last) { path.removeLast() }
    if path.hasPrefix("file://") { path = String(path.dropFirst("file://".count)) }
    guard !path.isEmpty, !path.hasSuffix("/") else { return nil }
    return path
  }
}
