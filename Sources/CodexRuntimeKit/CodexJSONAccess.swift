import Foundation

/// Generic JSON traversal/coercion helpers the Codex protocol parsers ride on,
/// moved from CodexNativeSessionController+JSONSupport.swift (2026-07-17).
/// Bodies are unchanged from the controller statics; the controller keeps
/// same-signature forwarders.
///
/// Coercion order in `intValue`/`int64Value` is load-bearing (typed integers
/// before NSNumber before trimmed-string parsing, floats bounds-checked) and
/// mirrors the app's JSONValueCoercion contract — do not reorder.
public enum CodexJSONAccess {
	// MARK: - Deterministic traversal contract
	//
	// The first* helpers walk JSON with an EXPLICIT order (2026-07-18) —
	// never dictionary hash order:
	//   1. Direct matches beat descendants at every dictionary.
	//   2. Caller-supplied key order resolves direct-match ties; multiple
	//      dictionary keys normalizing to the same requested key resolve in
	//      (normalized, original) lexical order.
	//   3. Arrays retain index order.
	//   4. Dictionary descendants are visited in (normalized, original)
	//      lexical key order, depth-first.
	//   5. The Set overloads sort their keys lexically.
	// A direct-match key whose child fails coercion is skipped, and the scan
	// continues — same as the historical behavior.

	private static func orderedNormalizedKeys(from keys: [String]) -> [String] {
		var seen = Set<String>()
		var ordered: [String] = []
		for key in keys {
			let normalized = normalizeApprovalKey(key)
			if seen.insert(normalized).inserted {
				ordered.append(normalized)
			}
		}
		return ordered
	}

	private static func descendantKeys(of dictionary: [String: Any]) -> [String] {
		dictionary.keys.sorted { lhs, rhs in
			let ln = normalizeApprovalKey(lhs)
			let rn = normalizeApprovalKey(rhs)
			return ln == rn ? lhs < rhs : ln < rn
		}
	}

	public static func firstString(in value: Any, keys: [String]) -> String? {
		firstString(in: value, orderedNormalizedKeys: orderedNormalizedKeys(from: keys))
	}

	public static func firstString(in value: Any, normalizedKeys: Set<String>) -> String? {
		firstString(in: value, orderedNormalizedKeys: normalizedKeys.sorted())
	}

	private static func firstString(in value: Any, orderedNormalizedKeys: [String]) -> String? {
		switch value {
		case let array as [Any]:
			for element in array {
				if let match = firstString(in: element, orderedNormalizedKeys: orderedNormalizedKeys) {
					return match
				}
			}
			return nil
		case let dictionary as [String: Any]:
			let sortedKeys = descendantKeys(of: dictionary)
			for requestedKey in orderedNormalizedKeys {
				for key in sortedKeys where normalizeApprovalKey(key) == requestedKey {
					if let child = dictionary[key], let match = stringScalarValue(from: child) {
						return match
					}
				}
			}
			for key in sortedKeys {
				guard let child = dictionary[key],
					(child as? [String: Any]) != nil || (child as? [Any]) != nil else { continue }
				if let match = firstString(in: child, orderedNormalizedKeys: orderedNormalizedKeys) {
					return match
				}
			}
			return nil
		default:
			return nil
		}
	}

	public static func stringScalarValue(from value: Any?) -> String? {
		guard let value else {
			return nil
		}
		if let string = value as? String {
			let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
			return trimmed.isEmpty ? nil : trimmed
		}
		if let number = value as? NSNumber {
			return number.stringValue
		}
		if let array = value as? [String], !array.isEmpty {
			let joined = array.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
			return joined.isEmpty ? nil : joined
		}
		return nil
	}

	public static func boolScalarValue(from value: Any?) -> Bool? {
		guard let value else {
			return nil
		}
		if let bool = value as? Bool {
			return bool
		}
		if let number = value as? NSNumber {
			return number.boolValue
		}
		if let string = value as? String {
			switch string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
			case "true", "1", "yes":
				return true
			case "false", "0", "no":
				return false
			default:
				return nil
			}
		}
		return nil
	}

	public static func firstJSONObject(in value: Any, keys: [String]) -> [String: Any]? {
		firstJSONObject(in: value, orderedNormalizedKeys: orderedNormalizedKeys(from: keys))
	}

	public static func firstJSONObject(in value: Any, normalizedKeys: Set<String>) -> [String: Any]? {
		firstJSONObject(in: value, orderedNormalizedKeys: normalizedKeys.sorted())
	}

	private static func firstJSONObject(in value: Any, orderedNormalizedKeys: [String]) -> [String: Any]? {
		switch value {
		case let dictionary as [String: Any]:
			let sortedKeys = descendantKeys(of: dictionary)
			for requestedKey in orderedNormalizedKeys {
				for key in sortedKeys where normalizeApprovalKey(key) == requestedKey {
					if let object = dictionary[key] as? [String: Any], JSONSerialization.isValidJSONObject(object) {
						return object
					}
				}
			}
			for key in sortedKeys {
				guard let child = dictionary[key] else { continue }
				if let nested = firstJSONObject(in: child, orderedNormalizedKeys: orderedNormalizedKeys) {
					return nested
				}
			}
			return nil
		case let array as [Any]:
			for element in array {
				if let nested = firstJSONObject(in: element, orderedNormalizedKeys: orderedNormalizedKeys) {
					return nested
				}
			}
			return nil
		default:
			return nil
		}
	}

	public static func firstJSONString(in value: Any, keys: [String]) -> String? {
		firstJSONString(in: value, orderedNormalizedKeys: orderedNormalizedKeys(from: keys))
	}

	public static func firstJSONString(in value: Any, normalizedKeys: Set<String>) -> String? {
		firstJSONString(in: value, orderedNormalizedKeys: normalizedKeys.sorted())
	}

	private static func firstJSONString(in value: Any, orderedNormalizedKeys: [String]) -> String? {
		switch value {
		case let dictionary as [String: Any]:
			let sortedKeys = descendantKeys(of: dictionary)
			for requestedKey in orderedNormalizedKeys {
				for key in sortedKeys where normalizeApprovalKey(key) == requestedKey {
					guard let child = dictionary[key] else { continue }
					if let string = child as? String, !string.isEmpty {
						return string
					}
					if let json = encodeJSONObjectString(child) {
						return json
					}
				}
			}
			for key in sortedKeys {
				guard let child = dictionary[key] else { continue }
				if let nested = firstJSONString(in: child, orderedNormalizedKeys: orderedNormalizedKeys) {
					return nested
				}
			}
			return nil
		case let array as [Any]:
			for element in array {
				if let nested = firstJSONString(in: element, orderedNormalizedKeys: orderedNormalizedKeys) {
					return nested
				}
			}
			return nil
		default:
			return nil
		}
	}

	public static func encodeJSONObjectString(_ value: Any) -> String? {
		guard JSONSerialization.isValidJSONObject(value) else { return nil }
		guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted]),
			  let json = String(data: data, encoding: .utf8) else {
			return nil
		}
		return json
	}

	public static func normalizeApprovalKey(_ value: String) -> String {
		value
			.trimmingCharacters(in: .whitespacesAndNewlines)
			.lowercased()
			.replacingOccurrences(of: "_", with: "")
			.replacingOccurrences(of: "-", with: "")
	}

	public static func intValue(_ value: Any?) -> Int? {
		switch value {
		case let number as Int:
			return number
		case let number as Int64:
			return Int(number)
		case let number as UInt:
			return Int(number)
		case let number as UInt64:
			return Int(number)
		case let number as Double:
			return intValueFromFloatingPoint(number)
		case let number as Float:
			return intValueFromFloatingPoint(Double(number))
		case let number as NSNumber:
			return number.intValue
		case let text as String:
			let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
			guard !trimmed.isEmpty else { return nil }
			if let asInt = Int(trimmed) {
				return asInt
			}
			if let asDouble = Double(trimmed) {
				return intValueFromFloatingPoint(asDouble)
			}
			return nil
		default:
			return nil
		}
	}

	private static func intValueFromFloatingPoint(_ value: Double) -> Int? {
		guard value.isFinite else { return nil }
		guard value >= Double(Int.min), value <= Double(Int.max) else { return nil }
		return Int(value)
	}

	public static func int64Value(_ value: Any?) -> Int64? {
		switch value {
		case let number as Int:
			return Int64(number)
		case let number as Int64:
			return number
		case let number as UInt:
			guard number <= UInt(Int64.max) else { return nil }
			return Int64(number)
		case let number as UInt64:
			guard number <= UInt64(Int64.max) else { return nil }
			return Int64(number)
		case let number as Double:
			return int64ValueFromFloatingPoint(number)
		case let number as Float:
			return int64ValueFromFloatingPoint(Double(number))
		case let number as NSNumber:
			return number.int64Value
		case let text as String:
			let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
			guard !trimmed.isEmpty else { return nil }
			if let asInt64 = Int64(trimmed) {
				return asInt64
			}
			if let asDouble = Double(trimmed) {
				return int64ValueFromFloatingPoint(asDouble)
			}
			return nil
		default:
			return nil
		}
	}

	private static func int64ValueFromFloatingPoint(_ value: Double) -> Int64? {
		guard value.isFinite else { return nil }
		guard value >= Double(Int64.min), value <= Double(Int64.max) else { return nil }
		return Int64(value)
	}

	// MARK: - Dictionary primitives
	//
	// Byte-for-byte parity with the app's JSONValueCoercion contract (typed
	// value, then NSNumber, then — for int — trimmed-string parsing; string
	// falls back to NSNumber.stringValue so JSON bools yield "1"/"0"). The
	// coercion order is load-bearing; do not reorder.

	public static func object(from raw: String?) -> [String: Any]? {
		guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
			  !raw.isEmpty,
			  let data = raw.data(using: .utf8),
			  let json = try? JSONSerialization.jsonObject(with: data),
			  let object = json as? [String: Any] else {
			return nil
		}
		return object
	}

	public static func string(_ object: [String: Any], key: String) -> String? {
		if let value = object[key] as? String {
			return value
		}
		if let value = object[key] as? NSNumber {
			return value.stringValue
		}
		return nil
	}

	public static func bool(_ object: [String: Any], key: String) -> Bool? {
		if let value = object[key] as? Bool {
			return value
		}
		if let value = object[key] as? NSNumber {
			return value.boolValue
		}
		return nil
	}

	public static func int(_ object: [String: Any], key: String) -> Int? {
		if let value = object[key] as? Int {
			return value
		}
		if let value = object[key] as? NSNumber {
			return value.intValue
		}
		if let value = object[key] as? String {
			return Int(value.trimmingCharacters(in: .whitespacesAndNewlines))
		}
		return nil
	}
}
