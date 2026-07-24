import Foundation

// Moved verbatim from the app's CodexAppServerClient.swift (2026-07-17) so the
// typed wire representation — not `[String: Any]` — is the reusable protocol
// boundary. The client keeps its `decodeParams` adapter app-side.

public enum CodexJSONValue: Sendable, Codable, Equatable {
	case string(String)
	case number(Double)
	case bool(Bool)
	case object([String: CodexJSONValue])
	case array([CodexJSONValue])
	case null

	public init(from decoder: Decoder) throws {
		let container = try decoder.singleValueContainer()
		if container.decodeNil() { self = .null; return }
		if let b = try? container.decode(Bool.self) { self = .bool(b); return }
		if let d = try? container.decode(Double.self) { self = .number(d); return }
		if let s = try? container.decode(String.self) { self = .string(s); return }
		if let a = try? container.decode([CodexJSONValue].self) { self = .array(a); return }
		if let o = try? container.decode([String: CodexJSONValue].self) { self = .object(o); return }
		throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
	}

	public func encode(to encoder: Encoder) throws {
		var container = encoder.singleValueContainer()
		switch self {
		case .string(let v): try container.encode(v)
		case .number(let v): try container.encode(v)
		case .bool(let v): try container.encode(v)
		case .object(let v): try container.encode(v)
		case .array(let v): try container.encode(v)
		case .null: try container.encodeNil()
		}
	}

	public func toAny() -> Any {
		switch self {
		case .string(let value):
			return value
		case .number(let value):
			return value
		case .bool(let value):
			return value
		case .object(let value):
			return value.mapValues { $0.toAny() }
		case .array(let value):
			return value.map { $0.toAny() }
		case .null:
			return NSNull()
		}
	}

	public static func from(_ value: Any) -> CodexJSONValue? {
		switch value {
		case let string as String:
			return .string(string)
		case let number as NSNumber:
			if CFGetTypeID(number) == CFBooleanGetTypeID() {
				return .bool(number.boolValue)
			}
			return .number(number.doubleValue)
		case let dict as [String: Any]:
			var output: [String: CodexJSONValue] = [:]
			for (key, value) in dict {
				if let converted = CodexJSONValue.from(value) {
					output[key] = converted
				}
			}
			return .object(output)
		case let array as [Any]:
			let converted = array.compactMap { CodexJSONValue.from($0) }
			return .array(converted)
		case _ as NSNull:
			return .null
		default:
			return nil
		}
	}
}
