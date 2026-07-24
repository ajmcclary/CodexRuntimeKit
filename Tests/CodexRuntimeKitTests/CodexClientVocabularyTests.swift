import XCTest
@testable import CodexRuntimeKit

final class CodexClientVocabularyTests: XCTestCase {
	func testBackoffScheduleIsDeterministicAndCapped() {
		let policy = CodexBackoffPolicy.default
		XCTAssertEqual(policy.delay(forAttempt: 0, jitterFraction: 0), 0.5)
		XCTAssertEqual(policy.delay(forAttempt: 1, jitterFraction: 0), 1.0)
		XCTAssertEqual(policy.delay(forAttempt: 2, jitterFraction: 0), 2.0)
		XCTAssertEqual(policy.delay(forAttempt: 10, jitterFraction: 0), 8.0)
	}

	func testRetryDelayOnlyForOverloadWithAttemptsRemaining() {
		let policy = CodexBackoffPolicy.default
		let overloaded = CodexClientError.rpcError(code: CodexBackoffPolicy.overloadErrorCode, message: "overloaded")
		XCTAssertEqual(policy.retryDelay(for: overloaded, attempt: 0), 0.5)
		XCTAssertNil(policy.retryDelay(for: overloaded, attempt: 3), "Exhausted attempts must not retry")
		XCTAssertNil(policy.retryDelay(for: CodexClientError.rpcError(code: -32000, message: "other"), attempt: 0))
		XCTAssertNil(policy.retryDelay(for: CodexClientError.requestFailed("nope"), attempt: 0))
	}

	func testTimeoutClassificationMatchesLegacyMessages() {
		XCTAssertTrue(CodexRequestTimeoutPolicy.isTimeoutError(CodexClientError.requestFailed("Request timed out after 30.0s")))
		XCTAssertFalse(CodexRequestTimeoutPolicy.isTimeoutError(CodexClientError.requestFailed("connection refused")))
		XCTAssertTrue(CodexRequestTimeoutPolicy.isTimeoutErrorMessage("  TIMED OUT AFTER 5s  "))
	}

	func testTransportPoisoningIsLimitedToThreadControlPlane() {
		XCTAssertTrue(CodexRequestTimeoutPolicy.shouldPoisonTransportOnTimeout(method: "thread/start"))
		XCTAssertTrue(CodexRequestTimeoutPolicy.shouldPoisonTransportOnTimeout(method: "thread/resume"))
		XCTAssertFalse(CodexRequestTimeoutPolicy.shouldPoisonTransportOnTimeout(method: "model/list"))
		XCTAssertFalse(CodexRequestTimeoutPolicy.shouldPoisonTransportOnTimeout(method: "turn/start"))
	}
}
