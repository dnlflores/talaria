import Foundation

/// A dynamically typed JSON value.
///
/// The Hermes gateway speaks JSON-RPC with payloads that grow fields between
/// releases, so the wire layer keeps values dynamic and the models read only
/// the fields they need.
public enum JSONValue: Sendable, Hashable {
  case null
  case bool(Bool)
  case number(Double)
  case string(String)
  case array([JSONValue])
  case object([String: JSONValue])
}

// MARK: - Parsing and serialization

extension JSONValue {
  public static func parse(_ data: Data) throws -> JSONValue {
    JSONValue(foundation: try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]))
  }

  public static func parse(_ text: String) throws -> JSONValue {
    try parse(Data(text.utf8))
  }

  init(foundation value: Any) {
    switch value {
    case let string as String:
      self = .string(string)
    case let number as NSNumber:
      // JSON booleans arrive as the CFBoolean singletons; everything else is numeric.
      self = CFGetTypeID(number) == CFBooleanGetTypeID() ? .bool(number.boolValue) : .number(number.doubleValue)
    case let array as [Any]:
      self = .array(array.map(JSONValue.init(foundation:)))
    case let object as [String: Any]:
      self = .object(object.mapValues(JSONValue.init(foundation:)))
    default:
      self = .null
    }
  }

  var foundation: Any {
    switch self {
    case .null: return NSNull()
    case .bool(let value): return value
    case .number(let value):
      // Whole numbers go out as integers so revisions and ids never become "2.0".
      if value.rounded() == value, abs(value) < 9e15 { return Int64(value) }
      return value
    case .string(let value): return value
    case .array(let values): return values.map(\.foundation)
    case .object(let fields): return fields.mapValues(\.foundation)
    }
  }

  public func data() -> Data {
    (try? JSONSerialization.data(withJSONObject: foundation, options: [.fragmentsAllowed, .withoutEscapingSlashes])) ?? Data("null".utf8)
  }

  public func text() -> String {
    String(decoding: data(), as: UTF8.self)
  }
}

// MARK: - Reading

extension JSONValue {
  /// Member lookup; a missing key or a non-object reads as `.null`.
  public subscript(key: String) -> JSONValue {
    if case .object(let fields) = self { return fields[key] ?? .null }
    return .null
  }

  public subscript(index: Int) -> JSONValue {
    if case .array(let values) = self, values.indices.contains(index) { return values[index] }
    return .null
  }

  public var isNull: Bool {
    if case .null = self { return true }
    return false
  }

  public var string: String? {
    if case .string(let value) = self { return value }
    return nil
  }

  public var double: Double? {
    switch self {
    case .number(let value): return value
    case .string(let value): return Double(value)
    default: return nil
    }
  }

  public var int: Int? {
    guard let value = double, value.isFinite, abs(value) < 9e15 else { return nil }
    return Int(value)
  }

  public var bool: Bool? {
    if case .bool(let value) = self { return value }
    return nil
  }

  public var array: [JSONValue]? {
    if case .array(let values) = self { return values }
    return nil
  }

  public var object: [String: JSONValue]? {
    if case .object(let fields) = self { return fields }
    return nil
  }

  /// The string, or `""` when the value is absent or not a string.
  public var stringValue: String { string ?? "" }

  /// Truthiness as the backend uses it: SQLite columns come back as 0/1, newer fields as booleans.
  public var truthy: Bool {
    switch self {
    case .bool(let value): return value
    case .number(let value): return value != 0
    case .string(let value): return !value.isEmpty && value != "0" && value.lowercased() != "false"
    case .array, .object: return true
    case .null: return false
    }
  }

  /// Scalars rendered as text (numbers without a trailing ".0"), for ids that may be strings or integers.
  public var scalarText: String? {
    switch self {
    case .string(let value): return value
    case .number(let value):
      if value.rounded() == value, abs(value) < 9e15 { return String(Int64(value)) }
      return String(value)
    case .bool(let value): return value ? "true" : "false"
    default: return nil
    }
  }

  /// A string field that sometimes arrives pre-parsed and sometimes as JSON text.
  public var parsedIfJSONString: JSONValue {
    if case .string(let text) = self, let first = text.first(where: { !$0.isWhitespace }), first == "{" || first == "[" {
      return (try? JSONValue.parse(text)) ?? self
    }
    return self
  }
}

// MARK: - Literals

extension JSONValue: ExpressibleByNilLiteral, ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral,
  ExpressibleByFloatLiteral, ExpressibleByStringLiteral, ExpressibleByStringInterpolation,
  ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral
{
  public init(nilLiteral: ()) { self = .null }
  public init(booleanLiteral value: Bool) { self = .bool(value) }
  public init(integerLiteral value: Int) { self = .number(Double(value)) }
  public init(floatLiteral value: Double) { self = .number(value) }
  public init(stringLiteral value: String) { self = .string(value) }
  public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
  public init(dictionaryLiteral elements: (String, JSONValue)...) {
    self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
  }
}

extension JSONValue {
  /// Builds an object, dropping fields whose value is `nil`.
  public static func fields(_ pairs: KeyValuePairs<String, JSONValue?>) -> JSONValue {
    var out: [String: JSONValue] = [:]
    for (key, value) in pairs { if let value { out[key] = value } }
    return .object(out)
  }
}
