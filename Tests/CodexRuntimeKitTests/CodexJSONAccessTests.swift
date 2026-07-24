import XCTest
@testable import CodexRuntimeKit

final class CodexJSONAccessTests: XCTestCase {
	// MARK: - Deterministic traversal contract (2026-07-18)

	func testFirstStringPrefersDirectMatchOverDescendant() {
		let payload: [String: Any] = [
			"tool_name": "direct",
			"a": ["tool_name": "nested"]
		]
		XCTAssertEqual(CodexJSONAccess.firstString(in: payload, keys: ["tool-name"]), "direct")
	}

	func testFirstStringResolvesDirectMatchTiesByCallerKeyOrder() {
		let payload: [String: Any] = [
			"command": "from-command",
			"tool_name": "from-tool-name"
		]
		XCTAssertEqual(
			CodexJSONAccess.firstString(in: payload, keys: ["tool-name", "command"]),
			"from-tool-name"
		)
		XCTAssertEqual(
			CodexJSONAccess.firstString(in: payload, keys: ["command", "tool-name"]),
			"from-command"
		)
	}

	func testFirstStringSkipsDirectMatchWhoseChildIsNotScalar() {
		let payload: [String: Any] = [
			"tool_name": ["not": "scalar"],
			"zz": ["tool_name": "nested-fallback"]
		]
		XCTAssertEqual(CodexJSONAccess.firstString(in: payload, keys: ["tool-name"]), "nested-fallback")
	}

	func testFirstStringDescendsDictionariesInNormalizedLexicalKeyOrder() {
		// "other" < "outer" lexically, so the descendant under "other" wins
		// even though both subtrees contain a match. This is the explicit
		// contract replacing the old hash-order-dependent behavior.
		let payload: [String: Any] = [
			"outer": ["tool_name": "under-outer"],
			"other": ["items": [["toolName": "under-other"]]]
		]
		XCTAssertEqual(CodexJSONAccess.firstString(in: payload, keys: ["tool-name"]), "under-other")
		XCTAssertNil(CodexJSONAccess.firstString(in: payload, keys: ["absent"]))
	}

	func testFirstStringArraysRetainIndexOrder() {
		let payload: [Any] = [
			["irrelevant": true],
			["tool_name": "first-hit"],
			["tool_name": "second-hit"]
		]
		XCTAssertEqual(CodexJSONAccess.firstString(in: payload, keys: ["tool-name"]), "first-hit")
	}

	func testFirstStringSetOverloadSortsKeysDeterministically() {
		let payload: [String: Any] = [
			"alpha": "a-value",
			"beta": "b-value"
		]
		// Sorted set keys: "alpha" < "beta" → alpha wins regardless of Set order.
		XCTAssertEqual(
			CodexJSONAccess.firstString(in: payload, normalizedKeys: Set(["beta", "alpha"])),
			"a-value"
		)
	}

	func testFirstJSONObjectAndJSONStringFollowTheSameContract() {
		let payload: [String: Any] = [
			"outer": ["config": ["z": 1]],
			"other": ["config": ["a": 2]]
		]
		XCTAssertEqual(
			CodexJSONAccess.firstJSONObject(in: payload, keys: ["config"])?["a"] as? Int,
			2,
			"descendant order is normalized-lexical: 'other' before 'outer'"
		)
		let stringPayload: [String: Any] = [
			"b_key": "tie-b",
			"a_key": "tie-a"
		]
		XCTAssertEqual(
			CodexJSONAccess.firstJSONString(in: stringPayload, keys: ["b-key", "a-key"]),
			"tie-b",
			"caller key order resolves direct ties"
		)
	}

	func testTraversalIsStableAcrossRepeatedCalls() {
		let payload: [String: Any] = [
			"outer": ["tool_name": "under-outer"],
			"other": ["items": [["toolName": "under-other"]]]
		]
		let first = CodexJSONAccess.firstString(in: payload, keys: ["tool-name"])
		for _ in 0..<100 {
			XCTAssertEqual(CodexJSONAccess.firstString(in: payload, keys: ["tool-name"]), first)
		}
	}

	func testStringScalarCoercionTrimsAndJoins() {
		XCTAssertEqual(CodexJSONAccess.stringScalarValue(from: "  hi  "), "hi")
		XCTAssertNil(CodexJSONAccess.stringScalarValue(from: "   "))
		XCTAssertEqual(CodexJSONAccess.stringScalarValue(from: NSNumber(value: 7)), "7")
		XCTAssertEqual(CodexJSONAccess.stringScalarValue(from: ["a", "b"]), "a b")
	}

	func testBoolScalarCoercionAcceptsWords() {
		XCTAssertEqual(CodexJSONAccess.boolScalarValue(from: "Yes"), true)
		XCTAssertEqual(CodexJSONAccess.boolScalarValue(from: "0"), false)
		XCTAssertNil(CodexJSONAccess.boolScalarValue(from: "maybe"))
	}

	func testIntCoercionOrderIsLoadBearing() {
		XCTAssertEqual(CodexJSONAccess.intValue(42), 42)
		XCTAssertEqual(CodexJSONAccess.intValue(" 42 "), 42)
		XCTAssertEqual(CodexJSONAccess.intValue(42.9), 42)
		XCTAssertNil(CodexJSONAccess.intValue(Double.infinity))
		XCTAssertNil(CodexJSONAccess.intValue("not-a-number"))
		XCTAssertEqual(CodexJSONAccess.int64Value("9007199254740993"), 9_007_199_254_740_993)
		XCTAssertNil(CodexJSONAccess.int64Value(Double.nan))
	}

	func testNormalizeApprovalKeyStripsSeparators() {
		XCTAssertEqual(CodexJSONAccess.normalizeApprovalKey(" Tool_Name-x "), "toolnamex")
	}

	func testCodexJSONValueRoundTripsAny() {
		let value = CodexJSONValue.from([
			"s": "text", "n": 1.5, "b": true, "arr": [1, 2], "nested": ["k": NSNull()]
		])
		guard case .object(let object)? = value else {
			return XCTFail("expected object")
		}
		XCTAssertEqual(object["s"], .string("text"))
		XCTAssertEqual(object["b"], .bool(true))
		let any = value?.toAny() as? [String: Any]
		XCTAssertEqual(any?["n"] as? Double, 1.5)
		XCTAssertTrue((any?["nested"] as? [String: Any])?["k"] is NSNull)
	}

	func testDictionaryPrimitiveCoercionParity() {
		let object: [String: Any] = [
			"s": "text", "n": NSNumber(value: 7), "b": true,
			"i": NSNumber(value: 3.9), "istr": " 12 "
		]
		XCTAssertEqual(CodexJSONAccess.string(object, key: "n"), "7")
		XCTAssertEqual(CodexJSONAccess.bool(object, key: "b"), true)
		XCTAssertEqual(CodexJSONAccess.int(object, key: "i"), 3, "NSNumber truncates via intValue")
		XCTAssertEqual(CodexJSONAccess.int(object, key: "istr"), 12)
		XCTAssertNil(CodexJSONAccess.string(object, key: "missing"))
		XCTAssertEqual(CodexJSONAccess.object(from: #"{"k":1}"#)?["k"] as? Int, 1)
		XCTAssertNil(CodexJSONAccess.object(from: "  "))
	}
}
