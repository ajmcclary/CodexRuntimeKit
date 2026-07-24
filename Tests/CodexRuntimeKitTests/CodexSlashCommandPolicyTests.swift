import XCTest
@testable import CodexRuntimeKit

/// Contract pins for the pure slash-command/goal policy promoted from
/// CodexAgentModeCoordinator (coordinator decomposition slice 1, 2026-07-18).
final class CodexSlashCommandPolicyTests: XCTestCase {
	func testSlashCommandVocabulary() {
		XCTAssertEqual(CodexNativeSlashCommand.allCases.map(\.rawValue), ["compact", "goal", "computer-use"])
		XCTAssertEqual(CodexNativeSlashCommand.compact.behavior, .controlPlane)
		XCTAssertEqual(CodexNativeSlashCommand.goal.behavior, .controlPlane)
		XCTAssertEqual(CodexNativeSlashCommand.computerUse.behavior, .userTurnWrapper)
		XCTAssertEqual(CodexNativeSlashCommand.goal.subtitle, "Set or view the goal for a long-running Codex task")
	}

	func testGoalSlashActionKeywordTable() {
		XCTAssertEqual(CodexGoalPolicy.goalSlashAction(from: ""), .show)
		XCTAssertEqual(CodexGoalPolicy.goalSlashAction(from: "   "), .show)
		XCTAssertEqual(CodexGoalPolicy.goalSlashAction(from: " Clear "), .clear)
		XCTAssertEqual(CodexGoalPolicy.goalSlashAction(from: "PAUSE"), .pause)
		XCTAssertEqual(CodexGoalPolicy.goalSlashAction(from: "resume"), .resume)
		XCTAssertEqual(CodexGoalPolicy.goalSlashAction(from: " ship the feature "), .setObjective("ship the feature"))
	}

	func testValidationMessageThresholdAndCommaFormatting() {
		XCTAssertNil(CodexGoalPolicy.goalObjectiveValidationMessage(String(repeating: "a", count: 4_000)))
		let message = CodexGoalPolicy.goalObjectiveValidationMessage(String(repeating: "a", count: 4_001))
		XCTAssertNotNil(message)
		XCTAssertTrue(message?.contains("4,001 characters") == true, message ?? "nil")
		XCTAssertTrue(message?.contains("Limit: 4,000 characters") == true, message ?? "nil")
	}

	func testComposeWithoutWorkflowPassesTrimmedObjectiveThrough() {
		let result = CodexGoalPolicy.composeGoalObjective(rawObjective: "  do the thing  ", workflow: nil)
		XCTAssertEqual(result, .success(.init(objective: "do the thing")))
	}

	func testComposeWithWorkflowBuildsContextBlockAndPrefersWrappedText() {
		let workflow = CodexGoalPolicy.WorkflowContext(
			displayName: "Build",
			descriptionText: "Build things carefully",
			tooltipText: "tooltip",
			wrappedObjectiveText: "WRAPPED: do it"
		)
		guard case .success(let composition) = CodexGoalPolicy.composeGoalObjective(rawObjective: "do it", workflow: workflow) else {
			return XCTFail("expected success")
		}
		let expected = """
		User goal:
		do it

		RepoPrompt workflow context:
		Workflow: Build
		Description: Build things carefully
		Apply this workflow's intent while pursuing the Codex goal. This is goal context, not a separate user turn.

		Workflow instructions:
		WRAPPED: do it
		"""
		XCTAssertEqual(composition.objective, expected)
	}

	func testComposeFallsBackThroughInstructionCascade() {
		let workflow = CodexGoalPolicy.WorkflowContext(
			displayName: "Fallback",
			descriptionText: nil,
			tooltipText: "  tip text  ",
			wrappedObjectiveText: "   "
		)
		guard case .success(let composition) = CodexGoalPolicy.composeGoalObjective(rawObjective: "obj", workflow: workflow) else {
			return XCTFail("expected success")
		}
		XCTAssertTrue(composition.objective.hasSuffix("Workflow instructions:\ntip text"), composition.objective)
		XCTAssertTrue(composition.objective.contains("Description: tip text"), "tooltip doubles as description when description is empty")
	}

	func testComposeTruncatesInstructionExcerptWithEllipsisWithinBudget() {
		let longInstructions = String(repeating: "x", count: 5_000)
		let workflow = CodexGoalPolicy.WorkflowContext(
			displayName: "Long",
			descriptionText: "d",
			tooltipText: nil,
			wrappedObjectiveText: longInstructions
		)
		guard case .success(let composition) = CodexGoalPolicy.composeGoalObjective(rawObjective: "obj", workflow: workflow) else {
			return XCTFail("expected success")
		}
		XCTAssertLessThanOrEqual(composition.objective.count, CodexGoalPolicy.maxThreadGoalObjectiveCharacters)
		XCTAssertTrue(composition.objective.hasSuffix("…"))
	}

	func testComposeFailsWhenObjectiveTooLongOrContextLeavesNoBudget() {
		let tooLong = String(repeating: "a", count: 4_001)
		guard case .failure(let message) = CodexGoalPolicy.composeGoalObjective(rawObjective: tooLong, workflow: nil) else {
			return XCTFail("expected failure")
		}
		XCTAssertTrue(message.contains("too long"))
		let hugeObjective = String(repeating: "b", count: 3_990)
		let workflow = CodexGoalPolicy.WorkflowContext(
			displayName: "W", descriptionText: nil, tooltipText: nil, wrappedObjectiveText: "i"
		)
		guard case .failure(let contextMessage) = CodexGoalPolicy.composeGoalObjective(rawObjective: hugeObjective, workflow: workflow) else {
			return XCTFail("expected context-budget failure")
		}
		XCTAssertTrue(contextMessage.contains("too long to include the selected workflow context"), contextMessage)
	}

	func testFormatThreadGoalWithAndWithoutBudget() {
		let base = CodexThreadGoal(
			threadID: "t", objective: "obj", status: .active,
			tokenBudget: 100, tokensUsed: 42, timeUsedSeconds: 0, createdAt: 0, updatedAt: 0
		)
		XCTAssertEqual(
			CodexGoalPolicy.formatThreadGoal(base),
			"Current Codex goal:\nobj\n\nStatus: Active\nTokens: 42/100"
		)
		let unbudgeted = CodexThreadGoal(
			threadID: "t", objective: "obj", status: .paused,
			tokenBudget: nil, tokensUsed: 7, timeUsedSeconds: 0, createdAt: 0, updatedAt: 0
		)
		XCTAssertEqual(
			CodexGoalPolicy.formatThreadGoal(unbudgeted),
			"Current Codex goal:\nobj\n\nStatus: Paused\nTokens used: 7"
		)
		XCTAssertEqual(CodexGoalPolicy.statusDisplayName(.budgetLimited), "Budget limited")
		XCTAssertEqual(CodexGoalPolicy.statusDisplayName(.complete), "Complete")
	}
}
