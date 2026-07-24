import XCTest
@testable import CodexRuntimeKit

/// Characterization of the parser surface moved from the controller's
/// ToolEvents extension. Payload shapes mirror the app-side shim suites
/// (CodexNativeSessionControllerCommandExecutionTests /
/// InboundEventCoverageTests), which continue to gate the same behavior
/// through the controller forwarders.
final class CodexToolEventParsingTests: XCTestCase {
	private struct PolicyStub: CodexToolNamePolicy {
		var mcpServerName: String { "RepoPrompt" }
		func hasExplicitServerPrefix(_ rawName: String) -> Bool {
			rawName.lowercased().hasPrefix("mcp__repoprompt__")
		}
		func matchesServerIdentifier(_ rawValue: String?) -> Bool {
			rawValue?.lowercased() == "repoprompt"
		}
		func normalizeToolName(_ rawName: String) -> String {
			rawName.lowercased()
		}
	}

	private func makeNormalizer() -> CodexToolEventNormalizer {
		CodexToolEventNormalizer(toolNamePolicy: PolicyStub())
	}

	func testCommandExecutionItemLifecycleParsesCallAndResult() {
		let normalizer = makeNormalizer()
		let started: [String: Any] = [
			"item": [
				"id": "item-1",
				"type": "commandExecution",
				"command": "ls -la",
				"status": "inProgress"
			]
		]
		guard case .call(let name, _, _, _)? = normalizer.parseToolLifecycleEvent(method: "item/started", params: started) else {
			return XCTFail("expected call event")
		}
		XCTAssertEqual(name, "bash")

		let completed: [String: Any] = [
			"item": [
				"id": "item-1",
				"type": "commandExecution",
				"command": "ls -la",
				"status": "completed",
				"exitCode": 0,
				"aggregatedOutput": "file.txt"
			]
		]
		guard case .result(let rname, _, _, let resultJSON, let isError, _)? = normalizer.parseToolLifecycleEvent(method: "item/completed", params: completed) else {
			return XCTFail("expected result event")
		}
		XCTAssertEqual(rname, "bash")
		XCTAssertEqual(isError, false)
		XCTAssertTrue(resultJSON.contains(#""status":"completed""#))
	}

	func testRepoPromptToolNameNormalizesThroughPolicy() {
		let normalizer = makeNormalizer()
		let candidate: [String: Any] = [
			"name": "mcp__RepoPrompt__ApplyEdits",
			"type": "mcpToolCall"
		]
		XCTAssertEqual(
			normalizer.normalizedToolName(from: candidate),
			"mcp__RepoPrompt__mcp__repoprompt__applyedits"
		)
	}

	func testFileChangeOutputDeltaSuppressedAfterTerminal() {
		let normalizer = makeNormalizer()
		let deltaParams: [String: Any] = [
			"msg": ["itemId": "fc-1", "delta": "patching...\n"]
		]
		XCTAssertNotNil(normalizer.parseFileChangeOutputDeltaEvent(params: deltaParams))
		normalizer.fileChangeStreamCompleted(itemID: "fc-1")
		XCTAssertNil(normalizer.parseFileChangeOutputDeltaEvent(params: deltaParams))
	}

	func testExecCommandBeginAndEndEventsParse() {
		let normalizer = makeNormalizer()
		let begin: [String: Any] = [
			"msg": [
				"type": "exec_command_begin",
				"call_id": "call-9",
				"command": ["bash", "-lc", "sleep 1"]
			]
		]
		let beginEvent = normalizer.parseExecCommandBeginEvent(params: begin)
		XCTAssertNotNil(beginEvent)
		XCTAssertEqual(beginEvent?.dedupKey, "call-9")

		let end: [String: Any] = [
			"msg": [
				"type": "exec_command_end",
				"call_id": "call-9",
				"exit_code": 0,
				"stdout": "done"
			]
		]
		let endEvent = normalizer.parseExecCommandEndEvent(params: end)
		XCTAssertNotNil(endEvent)
		XCTAssertEqual(endEvent?.dedupKey, "call-9")
	}

	func testInvocationIDIsDeterministicForNonUUIDItemIDs() {
		let normalizer = makeNormalizer()
		let a = normalizer.invocationID(from: "call_abc123")
		let b = normalizer.invocationID(from: "call_abc123")
		XCTAssertNotNil(a)
		XCTAssertEqual(a, b)
		XCTAssertNotEqual(a, normalizer.invocationID(from: "call_other"))
	}
}
