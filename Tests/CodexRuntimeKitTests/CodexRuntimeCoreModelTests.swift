import XCTest
@testable import CodexRuntimeKit

final class CodexRuntimeCoreModelTests: XCTestCase {
	func testThreadSnapshotProjectsSessionRefAndActivity() {
		let snapshot = CodexThreadSnapshot(
			conversationID: "conv-1",
			rolloutPath: "/tmp/rollout.jsonl",
			model: "gpt-5.2-codex",
			reasoningEffort: "high",
			runtimeStatus: .active(activeFlags: ["running"]),
			currentTurnID: "turn-2",
			activeTurnIDs: ["turn-2"],
			latestTurnStatus: .completed
		)
		XCTAssertEqual(
			snapshot.sessionRef,
			CodexSessionRef(
				conversationID: "conv-1",
				rolloutPath: "/tmp/rollout.jsonl",
				model: "gpt-5.2-codex",
				reasoningEffort: "high"
			)
		)
		XCTAssertEqual(snapshot.activeFlags, ["running"])
		XCTAssertTrue(snapshot.hasActiveTurn)
	}

	func testIdleSnapshotWithoutTurnsIsInactive() {
		let snapshot = CodexThreadSnapshot(
			conversationID: "conv-1",
			rolloutPath: nil,
			model: nil,
			reasoningEffort: nil,
			runtimeStatus: .idle,
			currentTurnID: nil,
			activeTurnIDs: [],
			latestTurnStatus: nil
		)
		XCTAssertFalse(snapshot.hasActiveTurn)
		XCTAssertEqual(snapshot.activeFlags, [])
	}

	func testAuthTokensRefreshResponsePayloadOmitsNilPlanType() {
		let withPlan = CodexChatgptAuthTokensRefreshResponse(
			accessToken: "token",
			chatgptAccountID: "acct",
			chatgptPlanType: "pro"
		)
		XCTAssertEqual(withPlan.payload["chatgptPlanType"] as? String, "pro")

		let withoutPlan = CodexChatgptAuthTokensRefreshResponse(
			accessToken: "token",
			chatgptAccountID: "acct",
			chatgptPlanType: nil
		)
		XCTAssertNil(withoutPlan.payload["chatgptPlanType"])
		XCTAssertEqual(withoutPlan.payload["accessToken"] as? String, "token")
		XCTAssertEqual(withoutPlan.payload["chatgptAccountId"] as? String, "acct")
	}
}
