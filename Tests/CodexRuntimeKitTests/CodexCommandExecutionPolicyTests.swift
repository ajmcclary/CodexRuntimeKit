import XCTest
import AgentRuntimeKit
@testable import CodexRuntimeKit

/// Contract tests for the pure command-execution policy promoted from
/// CodexAgentModeCoordinator (command-execution phase, 2026-07-18). Fixtures
/// are derived from the moved bodies — these pin, they don't redesign.
final class CodexCommandExecutionPolicyTests: XCTestCase {
	func testNormalizedExternalToolNameAliasesAndSuffixes() {
		XCTAssertEqual(CodexCommandExecutionPolicy.normalizedExternalToolName("functions.local_shell"), "bash")
		XCTAssertEqual(CodexCommandExecutionPolicy.normalizedExternalToolName("EXEC_COMMAND"), "bash")
		XCTAssertEqual(CodexCommandExecutionPolicy.normalizedExternalToolName("web_search_request"), "search")
		XCTAssertEqual(CodexCommandExecutionPolicy.normalizedExternalToolName("ns.custom_tool"), "custom_tool")
		XCTAssertNil(CodexCommandExecutionPolicy.normalizedExternalToolName("  "))
		XCTAssertNil(CodexCommandExecutionPolicy.normalizedExternalToolName(nil))
	}

	func testCommandExtractionPriorityArgvJoinAndUnquoting() {
		XCTAssertEqual(CodexCommandExecutionPolicy.extractCommandFromArgsJSON(#"{"command":["ls","-la"]}"#), "ls -la")
		XCTAssertEqual(CodexCommandExecutionPolicy.extractCommandFromArgsJSON(#"{"cmd":"'ls -la'"}"#), "ls -la")
		XCTAssertEqual(CodexCommandExecutionPolicy.extractCommandFromArgsJSON(#"{"invocation":{"args":["echo","hi"]}}"#), "echo hi")
		XCTAssertEqual(CodexCommandExecutionPolicy.extractCommandFromArgsJSON("not json"), "not json")
		XCTAssertNil(CodexCommandExecutionPolicy.extractCommandFromArgsJSON("  "))
		XCTAssertNil(CodexCommandExecutionPolicy.extractCommandFromArgsJSON(nil))
	}

	func testInitialRunningJSONEmbedsCommandAndProcessID() throws {
		let json = CodexCommandExecutionPolicy.initialRunningCommandExecutionJSON(
			argsJSON: #"{"command":"sleep 5","processId":"42"}"#
		)
		let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
		XCTAssertEqual(object["type"] as? String, "commandExecution")
		XCTAssertEqual(object["status"] as? String, "running")
		XCTAssertEqual(object["command"] as? String, "sleep 5")
		XCTAssertEqual(object["processId"] as? String, "42")
	}

	func testProcessIDCanonicalizationMatchesSessionPrefix() {
		XCTAssertTrue(CodexCommandExecutionPolicy.processIDsMatch("abc", "session:abc"))
		XCTAssertTrue(CodexCommandExecutionPolicy.processIDsMatch("session:abc", "abc"))
		XCTAssertFalse(CodexCommandExecutionPolicy.processIDsMatch("abc", "def"))
		XCTAssertFalse(CodexCommandExecutionPolicy.processIDsMatch(nil, "abc"))
		XCTAssertFalse(CodexCommandExecutionPolicy.processIDsMatch("  ", "abc"))
	}

	func testBashExecutionKeyPriorityInvocationSignatureProcess() {
		let id = UUID()
		XCTAssertEqual(
			CodexCommandExecutionPolicy.bashExecutionKey(invocationID: id, fallbackSignature: "sig", processID: "p"),
			"invocation:\(id.uuidString)"
		)
		XCTAssertEqual(
			CodexCommandExecutionPolicy.bashExecutionKey(invocationID: nil, fallbackSignature: " sig ", processID: "p"),
			"signature:sig"
		)
		XCTAssertEqual(
			CodexCommandExecutionPolicy.bashExecutionKey(invocationID: nil, fallbackSignature: "  ", processID: "p"),
			"process:p"
		)
		XCTAssertNil(CodexCommandExecutionPolicy.bashExecutionKey(invocationID: nil, fallbackSignature: nil, processID: nil))
	}

	func testRunningOutputMergeAndTailCapAt24k() {
		XCTAssertNil(CodexCommandExecutionPolicy.mergeCommandRunningOutput(existing: nil, incoming: ""))
		XCTAssertNil(CodexCommandExecutionPolicy.mergeCommandRunningOutput(existing: "", incoming: nil))
		XCTAssertEqual(CodexCommandExecutionPolicy.mergeCommandRunningOutput(existing: "a", incoming: "b"), "ab")
		let long = String(repeating: "x", count: 30_000)
		let merged = CodexCommandExecutionPolicy.mergeCommandRunningOutput(existing: long, incoming: "TAIL")
		XCTAssertEqual(merged?.count, 24_000)
		XCTAssertTrue(merged?.hasSuffix("TAIL") == true)
	}

	func testMergeRunningUpdatesPrefersIncomingIDsAndORsSeal() {
		let a = CodexCommandExecutionRunningUpdate(
			invocationID: nil, processID: "1", appendedOutput: "x", sealsAssistantBoundary: true
		)
		let b = CodexCommandExecutionRunningUpdate(
			invocationID: UUID(), processID: nil, appendedOutput: "y", sealsAssistantBoundary: false
		)
		let merged = CodexCommandExecutionPolicy.mergeCommandRunningUpdates(a, with: b)
		XCTAssertEqual(merged.invocationID, b.invocationID)
		XCTAssertEqual(merged.processID, "1")
		XCTAssertEqual(merged.appendedOutput, "xy")
		XCTAssertTrue(merged.sealsAssistantBoundary)
	}

	func testUpdateKeyPrefersProcessThenInvocationThenUnknown() {
		let id = UUID()
		XCTAssertEqual(
			CodexCommandExecutionPolicy.commandRunningUpdateKey(.init(invocationID: id, processID: "p", appendedOutput: nil)),
			"process:p"
		)
		XCTAssertEqual(
			CodexCommandExecutionPolicy.commandRunningUpdateKey(.init(invocationID: id, processID: nil, appendedOutput: nil)),
			"invocation:\(id.uuidString)"
		)
		XCTAssertEqual(
			CodexCommandExecutionPolicy.commandRunningUpdateKey(.init(invocationID: nil, processID: "", appendedOutput: nil)),
			"unknown"
		)
	}

	func testCoalescingDelaySelection() {
		let policy = CodexCommandExecutionPolicy.Coalescing.default
		XCTAssertEqual(
			policy.delayNanos(for: .init(invocationID: nil, processID: "p", appendedOutput: "out", sealsAssistantBoundary: true)),
			75_000_000
		)
		XCTAssertEqual(
			policy.delayNanos(for: .init(invocationID: nil, processID: "p", appendedOutput: "out")),
			225_000_000
		)
		XCTAssertEqual(
			policy.delayNanos(for: .init(invocationID: nil, processID: "p", appendedOutput: nil)),
			75_000_000
		)
	}

	func testTerminalStatusJSONSynthesizesExitCodeAndNormalizesProcessID() throws {
		let json = CodexCommandExecutionPolicy.withCommandExecutionTerminalStatus(
			raw: #"{"process_id":"9","status":"running"}"#,
			status: "completed"
		)
		let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
		XCTAssertEqual(object["status"] as? String, "completed")
		XCTAssertEqual(object["exitCode"] as? Int, 0)
		XCTAssertEqual(object["processId"] as? String, "9")
		XCTAssertNil(object["process_id"])
		XCTAssertEqual(object["type"] as? String, "commandExecution")

		let failed = CodexCommandExecutionPolicy.withCommandExecutionTerminalStatus(raw: "plain text", status: "failed")
		let failedObject = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(failed.utf8)) as? [String: Any])
		XCTAssertEqual(failedObject["exitCode"] as? Int, 1)
		XCTAssertEqual(failedObject["aggregatedOutput"] as? String, "plain text")

		let existingExit = CodexCommandExecutionPolicy.withCommandExecutionTerminalStatus(
			raw: #"{"exit_code":7}"#,
			status: "failed"
		)
		let existingExitObject = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(existingExit.utf8)) as? [String: Any])
		XCTAssertNil(existingExitObject["exitCode"], "existing exit_code must suppress synthesis")
		XCTAssertEqual(existingExitObject["exit_code"] as? Int, 7)
	}

	func testTurnStatusMapsAndFallbackJSON() {
		XCTAssertEqual(CodexCommandExecutionPolicy.terminalCommandStatusWord(for: .completed), "completed")
		XCTAssertEqual(CodexCommandExecutionPolicy.terminalCommandStatusWord(for: .interrupted), "cancelled")
		XCTAssertEqual(CodexCommandExecutionPolicy.terminalCommandStatusWord(for: .failed), "failed")
		XCTAssertEqual(CodexCommandExecutionPolicy.agentSessionRunState(for: .interrupted), .cancelled)
		XCTAssertEqual(CodexCommandExecutionPolicy.codexTurnStatus(forTerminalState: .cancelled), .interrupted)
		XCTAssertNil(CodexCommandExecutionPolicy.codexTurnStatus(forTerminalState: .running))
		XCTAssertNil(CodexCommandExecutionPolicy.codexTurnStatus(forTerminalState: .idle))
		let fallback = CodexCommandExecutionPolicy.fallbackToolResultJSON(for: .failed)
		XCTAssertTrue(fallback.contains("No tool result payload was received before the turn ended."), fallback)
		XCTAssertTrue(fallback.contains(#""status" : "failed""#), fallback)
		XCTAssertTrue(CodexCommandExecutionPolicy.fallbackToolResultJSON(for: .interrupted).contains(#""status" : "unknown""#))
	}

	func testLateOutputMergeIntoTerminalJSON() throws {
		let raw = #"{"type":"commandExecution","status":"failed","aggregated_output":"head"}"#
		let merged = try XCTUnwrap(
			CodexCommandExecutionPolicy.commandExecutionTerminalResultJSONByMergingLateOutput(raw: raw, appendedOutput: "tail")
		)
		let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(merged.utf8)) as? [String: Any])
		XCTAssertEqual(object["aggregatedOutput"] as? String, "headtail")
		XCTAssertNil(object["aggregated_output"])
		XCTAssertNil(CodexCommandExecutionPolicy.commandExecutionTerminalResultJSONByMergingLateOutput(raw: raw, appendedOutput: nil))
		XCTAssertNil(CodexCommandExecutionPolicy.commandExecutionTerminalResultJSONByMergingLateOutput(raw: nil, appendedOutput: "x"))
	}

	func testReviveTerminalLaunchForcesRunningAndStripsTerminalFields() throws {
		let raw = #"""
		{"type":"commandExecution","status":"failed","exitCode":1,"exit_code":1,"code":1,"summary_only":true,"summaryOnly":true,"processId":"4242","command":"npm start","aggregatedOutput":"boot\n"}
		"""#
		let revived = CodexCommandExecutionPolicy.commandExecutionRunningResultJSONByRevivingTerminalLaunch(
			raw: raw,
			appendedOutput: "ready\n",
			processID: "4242"
		)
		let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(revived.utf8)) as? [String: Any])
		XCTAssertEqual(object["type"] as? String, "commandExecution")
		XCTAssertEqual(object["status"] as? String, "running")
		// Every terminal-status marker is dropped so the card renders as running.
		XCTAssertNil(object["exitCode"])
		XCTAssertNil(object["exit_code"])
		XCTAssertNil(object["code"])
		XCTAssertNil(object["summary_only"])
		XCTAssertNil(object["summaryOnly"])
		// Command context is preserved; late output is merged onto the existing output.
		XCTAssertEqual(object["command"] as? String, "npm start")
		XCTAssertEqual(object["aggregatedOutput"] as? String, "boot\nready\n")
	}

	func testReviveTerminalLaunchNormalizesProcessIDAndCapsOutput() throws {
		// A snake_case process id on the raw payload is normalized to processId
		// via the supplied PID; the merged output is tail-capped at 24k.
		let longExisting = String(repeating: "e", count: 30_000)
		let raw = "{\"type\":\"commandExecution\",\"status\":\"failed\",\"process_id\":\"9\",\"aggregatedOutput\":\"\(longExisting)\"}"
		let revived = CodexCommandExecutionPolicy.commandExecutionRunningResultJSONByRevivingTerminalLaunch(
			raw: raw,
			appendedOutput: "TAILMARK",
			processID: "9"
		)
		let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(revived.utf8)) as? [String: Any])
		XCTAssertEqual(object["processId"] as? String, "9")
		XCTAssertNil(object["process_id"])
		let output = try XCTUnwrap(object["aggregatedOutput"] as? String)
		XCTAssertEqual(output.count, 24_000)
		XCTAssertTrue(output.hasSuffix("TAILMARK"))
	}

	func testReviveTerminalLaunchWithMalformedOrNonObjectRawStillProducesRunningJSON() throws {
		for raw in ["not json at all", "[1,2,3]", "", "{ broken"] {
			let revived = CodexCommandExecutionPolicy.commandExecutionRunningResultJSONByRevivingTerminalLaunch(
				raw: raw,
				appendedOutput: nil,
				processID: "  "
			)
			let object = try XCTUnwrap(
				try JSONSerialization.jsonObject(with: Data(revived.utf8)) as? [String: Any],
				"raw=\(raw)"
			)
			XCTAssertEqual(object["type"] as? String, "commandExecution", "raw=\(raw)")
			XCTAssertEqual(object["status"] as? String, "running", "raw=\(raw)")
			// A blank process id is not written.
			XCTAssertNil(object["processId"], "raw=\(raw)")
		}
	}

	func testIsCandidatePOSIXProcessID() {
		XCTAssertTrue(CodexCommandExecutionPolicy.isCandidatePOSIXProcessID("4242"))
		XCTAssertTrue(CodexCommandExecutionPolicy.isCandidatePOSIXProcessID("1"))
		XCTAssertFalse(CodexCommandExecutionPolicy.isCandidatePOSIXProcessID("0"))
		XCTAssertFalse(CodexCommandExecutionPolicy.isCandidatePOSIXProcessID("-1"))
		XCTAssertFalse(CodexCommandExecutionPolicy.isCandidatePOSIXProcessID("session:27588"))
		XCTAssertFalse(CodexCommandExecutionPolicy.isCandidatePOSIXProcessID("cancelled-123"))
		XCTAssertFalse(CodexCommandExecutionPolicy.isCandidatePOSIXProcessID(""))
		XCTAssertFalse(CodexCommandExecutionPolicy.isCandidatePOSIXProcessID("  "))
		// Beyond Int32 range: not a valid pid handle.
		XCTAssertFalse(CodexCommandExecutionPolicy.isCandidatePOSIXProcessID("99999999999"))
	}
}
