import Foundation

// SEARCH-HELPER: slash command, goal policy, compose objective, workflow context, format goal
// Pure slash-command vocabulary and thread-goal parsing/composition/formatting,
// moved from CodexAgentModeCoordinator (coordinator decomposition slice 1,
// 2026-07-18). Bodies are verbatim from the coordinator statics; the
// coordinator keeps nested typealiases + same-signature forwarders. The one
// app-policy dependency — AgentWorkflowDefinition.wrapUserText (template
// wrapping over ClaudeCodeCommands) — arrives precomputed via
// `WorkflowContext.wrappedObjectiveText`.

/// The native slash commands the Codex coordinator understands.
public enum CodexNativeSlashCommand: String, CaseIterable, Sendable {
	case compact
	case goal
	case computerUse = "computer-use"

	public var subtitle: String {
		switch self {
		case .compact:
			return "Compact the active Codex thread context"
		case .goal:
			return "Set or view the goal for a long-running Codex task"
		case .computerUse:
			return "Guide Codex through a computer-use workflow"
		}
	}

	public var behavior: CodexNativeSlashCommandBehavior {
		switch self {
		case .compact, .goal:
			return .controlPlane
		case .computerUse:
			return .userTurnWrapper
		}
	}
}

public enum CodexNativeSlashCommandBehavior: Sendable, Equatable {
	case controlPlane
	case userTurnWrapper
}

/// Thread-goal slash-command parsing, objective composition, and goal
/// formatting. Everything here is a pure function of its inputs.
public enum CodexGoalPolicy {
	public static let maxThreadGoalObjectiveCharacters = 4_000

	public enum GoalSlashAction: Equatable, Sendable {
		case show
		case clear
		case pause
		case resume
		case setObjective(String)
	}

	public static func goalSlashAction(from argumentsText: String) -> GoalSlashAction {
		let trimmed = argumentsText.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !trimmed.isEmpty else { return .show }
		switch trimmed.lowercased() {
		case "clear":
			return .clear
		case "pause":
			return .pause
		case "resume":
			return .resume
		default:
			return .setObjective(trimmed)
		}
	}

	public static func goalObjectiveValidationMessage(_ objective: String) -> String? {
		let actual = objective.count
		guard actual > maxThreadGoalObjectiveCharacters else { return nil }
		return "Goal objective is too long: \(formattedCharacterCount(actual)) characters. Limit: \(formattedCharacterCount(maxThreadGoalObjectiveCharacters)) characters. Put longer instructions in a file and refer to that file in the goal, for example: /goal follow the instructions in docs/goal.md."
	}

	/// The app-computed workflow values `composeGoalObjective` rides on.
	/// `wrappedObjectiveText` is the workflow's template applied to the
	/// (trimmed) raw objective — template wrapping is app policy and stays
	/// out of this package.
	public struct WorkflowContext: Sendable, Equatable {
		public let displayName: String
		public let descriptionText: String?
		public let tooltipText: String?
		public let wrappedObjectiveText: String?

		public init(
			displayName: String,
			descriptionText: String?,
			tooltipText: String?,
			wrappedObjectiveText: String?
		) {
			self.displayName = displayName
			self.descriptionText = descriptionText
			self.tooltipText = tooltipText
			self.wrappedObjectiveText = wrappedObjectiveText
		}
	}

	public struct GoalObjectiveComposition: Equatable, Sendable {
		public let objective: String

		public init(objective: String) {
			self.objective = objective
		}
	}

	public enum GoalObjectiveCompositionResult: Equatable, Sendable {
		case success(GoalObjectiveComposition)
		case failure(String)
	}

	public static func composeGoalObjective(
		rawObjective: String,
		workflow: WorkflowContext?
	) -> GoalObjectiveCompositionResult {
		let rawObjective = rawObjective.trimmingCharacters(in: .whitespacesAndNewlines)
		if let message = goalObjectiveValidationMessage(rawObjective) {
			return .failure(message)
		}
		guard let workflow else {
			return .success(GoalObjectiveComposition(objective: rawObjective))
		}

		let description = workflow.descriptionText?.trimmingCharacters(in: .whitespacesAndNewlines)
		let tooltip = workflow.tooltipText?.trimmingCharacters(in: .whitespacesAndNewlines)
		var contextLines = [
			"User goal:",
			rawObjective,
			"",
			"RepoPrompt workflow context:",
			"Workflow: \(workflow.displayName)"
		]
		if let description, !description.isEmpty {
			contextLines.append("Description: \(description)")
		} else if let tooltip, !tooltip.isEmpty {
			contextLines.append("Description: \(tooltip)")
		}
		contextLines.append("Apply this workflow's intent while pursuing the Codex goal. This is goal context, not a separate user turn.")
		let contextBlock = contextLines.joined(separator: "\n")

		let instructionSourceCandidates = [
			workflow.wrappedObjectiveText,
			description,
			tooltip,
			workflow.displayName
		]
		let instructionSource = instructionSourceCandidates
			.compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
			.first(where: { !$0.isEmpty }) ?? workflow.displayName
		let instructionsPrefix = "\n\nWorkflow instructions:\n"
		let fixedCount = contextBlock.count + instructionsPrefix.count
		guard fixedCount < maxThreadGoalObjectiveCharacters else {
			return .failure("Goal objective is too long to include the selected workflow context. Shorten the objective or clear the selected workflow before using /goal.")
		}
		let budget = maxThreadGoalObjectiveCharacters - fixedCount
		let instructionExcerpt: String
		if instructionSource.count <= budget {
			instructionExcerpt = instructionSource
		} else {
			let prefixLength = max(0, budget - 1)
			let prefix = instructionSource.prefix(prefixLength)
			instructionExcerpt = "\(prefix)…"
		}
		return .success(GoalObjectiveComposition(
			objective: contextBlock + instructionsPrefix + instructionExcerpt
		))
	}

	public static func formatThreadGoal(_ goal: CodexThreadGoal) -> String {
		var lines = [
			"Current Codex goal:",
			goal.objective,
			"",
			"Status: \(statusDisplayName(goal.status))"
		]
		if let tokenBudget = goal.tokenBudget {
			lines.append("Tokens: \(goal.tokensUsed)/\(tokenBudget)")
		} else {
			lines.append("Tokens used: \(goal.tokensUsed)")
		}
		return lines.joined(separator: "\n")
	}

	public static func statusDisplayName(_ status: CodexThreadGoalStatus) -> String {
		switch status {
		case .active:
			return "Active"
		case .paused:
			return "Paused"
		case .budgetLimited:
			return "Budget limited"
		case .complete:
			return "Complete"
		}
	}

	private static func formattedCharacterCount(_ value: Int) -> String {
		let raw = String(value)
		var output = ""
		for (offset, character) in raw.reversed().enumerated() {
			if offset > 0, offset % 3 == 0 {
				output.append(",")
			}
			output.append(character)
		}
		return String(output.reversed())
	}
}
