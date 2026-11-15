import Foundation

/// 任意 JSON 值：用来原样保存服务端返回的内容块（工具块、思考签名等），
/// 下一轮请求必须把这些块原样传回去。
enum JSONValue: Codable, Hashable {
  case null
  case bool(Bool)
  case number(Double)
  case string(String)
  case array([JSONValue])
  case object([String: JSONValue])

  init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if container.decodeNil() {
      self = .null
    } else if let value = try? container.decode(Bool.self) {
      self = .bool(value)
    } else if let value = try? container.decode(Double.self) {
      self = .number(value)
    } else if let value = try? container.decode(String.self) {
      self = .string(value)
    } else if let value = try? container.decode([JSONValue].self) {
      self = .array(value)
    } else {
      self = .object(try container.decode([String: JSONValue].self))
    }
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .null: try container.encodeNil()
    case .bool(let value): try container.encode(value)
    case .number(let value): try container.encode(value)
    case .string(let value): try container.encode(value)
    case .array(let value): try container.encode(value)
    case .object(let value): try container.encode(value)
    }
  }

  var stringValue: String? {
    if case .string(let value) = self { return value }
    return nil
  }

  var objectValue: [String: JSONValue]? {
    if case .object(let value) = self { return value }
    return nil
  }

  subscript(key: String) -> JSONValue? {
    get { objectValue?[key] }
    set {
      guard case .object(var dictionary) = self else { return }
      dictionary[key] = newValue
      self = .object(dictionary)
    }
  }

  static func from(_ value: Any) -> JSONValue {
    switch value {
    case let value as String: return .string(value)
    case let value as Bool: return .bool(value)
    case let value as Int: return .number(Double(value))
    case let value as Double: return .number(value)
    case let value as NSNumber:
      return .number(value.doubleValue)
    case let value as [Any]: return .array(value.map(JSONValue.from))
    case let value as [String: Any]:
      return .object(value.mapValues(JSONValue.from))
    default: return .null
    }
  }
}
