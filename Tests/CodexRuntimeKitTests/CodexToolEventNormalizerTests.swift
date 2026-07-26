import Synchronization
import XCTest
@testable import CodexRuntimeKit

private struct StubToolNamePolicy: CodexToolNamePolicy {
	var mcpServerName: String { "RepoPrompt" }
	func hasExplicitServerPrefix(_ rawName: String) -> Bool {
		rawName.hasPrefix("mcp__RepoPrompt__")
	}
	func matchesServerIdentifier(_ rawValue: String?) -> Bool {
		rawValue?.lowercased() == "repoprompt"
	}
	func normalizeToolName(_ rawName: String) -> String {
		rawName
	}
}

private func makeNormalizer(clock: (@Sendable () -> Date)? = nil) -> CodexToolEventNormalizer {
	if let clock {
		return CodexToolEventNormalizer(toolNamePolicy: StubToolNamePolicy(), clock: clock)
	}
	return CodexToolEventNormalizer(toolNamePolicy: StubToolNamePolicy())
}

final class CodexToolEventNormalizerTests: XCTestCase {
	func testDedupMarksFirstEmissionOnlyAndResetsAtTurnBoundary() {
		let normalizer = makeNormalizer()
		XCTAssertTrue(normalizer.markToolEventEmitted(key: "call:x"))
		XCTAssertFalse(normalizer.markToolEventEmitted(key: "call:x"))
		normalizer.resetForTurnBoundary()
		XCTAssertTrue(normalizer.markToolEventEmitted(key: "call:x"))
	}

	func testDedupKeyPrefersItemIDThenComposite() {
		let normalizer = makeNormalizer()
		XCTAssertEqual(normalizer.toolDedupKey(itemID: " item-1 ", toolName: "bash", argsJSON: nil, resultJSON: nil), "item-1")
		XCTAssertEqual(normalizer.toolDedupKey(itemID: "  ", toolName: "bash", argsJSON: "{}", resultJSON: nil), "bash|{}|")
	}

	func testMirrorRejectsCrossFamilyWithinTTLAndAcceptsAfterExpiry() {
		// The clock is read from a @Sendable closure, so the test's notion of
		// "now" needs a real owner rather than a captured var.
		let current = Mutex(Date(timeIntervalSince1970: 1_000_000))
		let normalizer = makeNormalizer(clock: { current.withLock { $0 } })
		XCTAssertTrue(normalizer.shouldAcceptCommandExecutionEvent(itemID: "item", family: .raw))
		XCTAssertFalse(normalizer.shouldAcceptCommandExecutionEvent(itemID: "item", family: .normalized))
		XCTAssertTrue(normalizer.shouldAcceptCommandExecutionEvent(itemID: "item", family: .raw))
		current.withLock { $0 = $0.addingTimeInterval(31 * 60) }
		XCTAssertTrue(normalizer.shouldAcceptCommandExecutionEvent(itemID: "item", family: .normalized))
	}

	func testMirrorAcceptsBlankItemIDsUnconditionally() {
		let normalizer = makeNormalizer()
		XCTAssertTrue(normalizer.shouldAcceptCommandExecutionEvent(itemID: nil, family: .raw))
		XCTAssertTrue(normalizer.shouldAcceptCommandExecutionEvent(itemID: "  ", family: .normalized))
	}

	func testFileChangeTerminalSuppressionAndRestartClears()  {
		let normalizer = makeNormalizer()
		let state = CodexToolEventNormalizer.FileChangeStreamState(
			itemID: "fc-1",
			invocationID: nil,
			argsJSON: nil,
			latestResultJSON: nil,
			accumulatedOutput: "",
			status: "running"
		)
		normalizer.fileChangeStreamStarted(state)
		XCTAssertNotNil(normalizer.fileChangeState(for: "fc-1"))
		normalizer.fileChangeStreamCompleted(itemID: "fc-1")
		XCTAssertNil(normalizer.fileChangeState(for: "fc-1"))
		XCTAssertTrue(normalizer.isFileChangeTerminal("fc-1"))
		normalizer.fileChangeStreamStarted(state)
		XCTAssertFalse(normalizer.isFileChangeTerminal("fc-1"))
	}

	func testResetSemanticsAreScoped() {
		let normalizer = makeNormalizer()
		_ = normalizer.markToolEventEmitted(key: "k")
		_ = normalizer.shouldAcceptCommandExecutionEvent(itemID: "item", family: .raw)
		normalizer.fileChangeStreamCompleted(itemID: "fc")

		normalizer.resetMirrorForBinding()
		XCTAssertFalse(normalizer.markToolEventEmitted(key: "k"), "binding reset must not clear dedup")
		XCTAssertTrue(normalizer.isFileChangeTerminal("fc"), "binding reset must not clear terminal IDs")
		XCTAssertTrue(normalizer.shouldAcceptCommandExecutionEvent(itemID: "item", family: .normalized), "mirror cleared")

		normalizer.resetForThreadRestore()
		XCTAssertFalse(normalizer.isFileChangeTerminal("fc"))
		XCTAssertFalse(normalizer.markToolEventEmitted(key: "k"), "thread restore must not clear dedup")

		normalizer.resetAll()
		XCTAssertTrue(normalizer.markToolEventEmitted(key: "k"))
	}
}
