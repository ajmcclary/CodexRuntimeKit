import XCTest
import AgentRuntimeKit
import CodexRuntimeKit

/// Public-API boundary contract for CodexRuntimeKit (the fifth migrate.md
/// extraction and the first provider-runtime promotion). The deep behavior
/// pins live in the per-family suites that moved with the code; this file
/// pins what those suites cannot: (1) every vocabulary family RepoPrompt
/// consumes stays PUBLIC — this file deliberately imports WITHOUT
/// `@testable`, so any accidental de-publicizing breaks compilation —
/// (2) the raw-value/wire formats that cross the package boundary as
/// persisted or protocol identity, and (3) that the AgentRuntimeKit types
/// crossing the boundary in public signatures stay reachable.
final class CodexRuntimeKitPublicAPIContractTests: XCTestCase {
	// Compile-time public-visibility pins, one alias per vocabulary family.
	// A tuple type references each member type without needing constructible
	// values; removal or de-publicizing of any member is a compile error.
	private typealias SessionFamily = (CodexSessionRef, CodexTurnStatus, CodexThreadSnapshot, CodexThreadSnapshot.RuntimeStatus)
	private typealias ThreadGoalFamily = (CodexThreadGoal, CodexThreadGoalStatus)
	private typealias EventFamily = (CodexRuntimeEvent, CodexReasoningDeltaPayload, CodexCommandExecutionRunningUpdate, CodexLivenessActivity, CodexErrorNotification)
	private typealias ClientVocabularyFamily = (CodexRemoteReasoningEffort, CodexRemoteModelUpgradeInfo, CodexRemoteModel, CodexServerNotification, CodexServerRequest, CodexClientError, CodexTransportTerminationReason, CodexRequestTimeoutPolicy)
	private typealias JSONFamily = (CodexJSONValue, CodexJSONAccess)
	private typealias ServerRequestFamily = (CodexServerRequestIssue, CodexChatgptAuthTokensRefreshRequest, CodexChatgptAuthTokensRefreshResponse, CodexChatgptAuthTokensRefreshHandler, CodexServerRequestRouting, CodexServerRequestParser)
	private typealias InterpretationFamily = (CodexNotificationInterpreter, CodexNotificationRoutingDecision, CodexThreadGoalParseError)
	private typealias ToolEventFamily = (CodexToolNamePolicy, CodexToolEventNormalizer, CodexToolEventNormalizer.FileChangeStreamState, CodexToolEventNormalizer.CommandExecutionEventFamily, CodexToolEventNormalizer.ToolLifecycleEvent, CodexToolEventNormalizer.ExecCommandBeginEvent, CodexToolEventNormalizer.ExecCommandEndEvent, CodexToolEventNormalizer.CommandExecutionPayloadHelper, CommandExecutionOutputSanitizer)
	private typealias CompatibilityFamily = (CodexCliVersion, CodexVersionAssessment, CodexCompatibilityPolicy, CodexProtocolLane, CodexCapabilityEndpoint, CodexCapabilityProbeOutcome, CodexCapabilityProbeResult, CodexCapabilityProbeClassifier, CodexProtocolKnownDivergence, CodexProtocolKnownDivergences, CodexRuntimeCompatibilitySnapshot, CodexRuntimeCompatibilitySnapshot.AuthMode, CodexProtocolLockSnapshot)
	private typealias AdmissionFamily = (CodexExperimentalRequirement, CodexExperimentalSurface, CodexExperimentalAdmission, CodexExperimentalAdmissionRecord)
	private typealias PolicyFamily = (CodexBackoffPolicy, CodexCommandExecutionPolicy, CodexCommandExecutionPolicy.Coalescing, CodexModelUpgradeAdvisor, CodexModelUpgradeRecommendation, CodexNativeSlashCommand, CodexNativeSlashCommandBehavior, CodexGoalPolicy, CodexGoalPolicy.GoalSlashAction, CodexGoalPolicy.WorkflowContext, CodexGoalPolicy.GoalObjectiveComposition, CodexGoalPolicy.GoalObjectiveCompositionResult)
	// AgentRuntimeKit types that cross this package's public signatures
	// (CodexServerRequest.id, CodexRuntimeEvent payload cases, the
	// notification interpreter's token-usage result, and the
	// command-execution policy's run-state bridging).
	private typealias CrossBoundaryFamily = (CodexAppServerRequestID, AgentApprovalRequest, AgentPermissionsRequest, AgentRequestUserInputRequest, AgentMCPElicitationRequest, AgentContextUsage, AgentSessionRunState)

	func testProtocolLockSnapshotValuesStayGeneratedIdentity() {
		// The generated CodexProtocolLockSnapshot travels with this package;
		// RepoPrompt's Scripts/update-codex-protocol regenerates it and the
		// app-side CodexProtocolLockTests asserts it matches the vendored
		// codex-protocol.lock.json. This pin catches accidental hand edits.
		XCTAssertEqual(CodexProtocolLockSnapshot.schemaTargetCliVersion, "0.144.6")
		XCTAssertEqual(
			CodexProtocolLockSnapshot.sourceBinarySha256,
			"80a3933d11a9d13ef806aa24f7bb8afc9169cfe4e9b09d6da6a92922cbde9cff"
		)
	}

	func testThreadGoalStatusRawValuesArePinnedWireIdentity() {
		// Raw strings are the goal-status wire/persisted identity.
		XCTAssertEqual(CodexThreadGoalStatus.active.rawValue, "active")
		XCTAssertEqual(CodexThreadGoalStatus.paused.rawValue, "paused")
		XCTAssertEqual(CodexThreadGoalStatus.budgetLimited.rawValue, "budgetLimited")
		XCTAssertEqual(CodexThreadGoalStatus.complete.rawValue, "complete")
	}

	func testNativeSlashCommandInventoryAndRawValuesArePinned() {
		XCTAssertEqual(CodexNativeSlashCommand.allCases, [.compact, .goal, .computerUse])
		XCTAssertEqual(
			CodexNativeSlashCommand.allCases.map(\.rawValue),
			["compact", "goal", "computer-use"]
		)
	}

	func testCodexJSONValueSurvivesCodableRoundTrip() throws {
		let value = CodexJSONValue.object([
			"items": .array([.string("x"), .number(1), .bool(true), .null])
		])
		let encoded = try JSONEncoder().encode(value)
		XCTAssertEqual(try JSONDecoder().decode(CodexJSONValue.self, from: encoded), value)
	}

	func testCliVersionParseAndOrderingContract() {
		let parsed = CodexCliVersion.parse(CodexProtocolLockSnapshot.schemaTargetCliVersion)
		XCTAssertEqual(parsed, CodexCliVersion(major: 0, minor: 144, patch: 6))
		XCTAssertTrue(CodexCliVersion(major: 0, minor: 144, patch: 6) < CodexCliVersion(major: 0, minor: 145, patch: 0))
	}

	func testServerRequestCarriesAgentRuntimeKitRequestID() {
		// Cross-boundary composition: the request identifier type is
		// AgentRuntimeKit's, reachable through this package's public surface.
		let request = CodexServerRequest(
			id: .int(7),
			method: "item/commandExecutionRequestApproval",
			params: [:]
		)
		XCTAssertEqual(request.id, CodexAppServerRequestID.int(7))
		XCTAssertEqual(request.method, "item/commandExecutionRequestApproval")
	}
}
