import Foundation

// Thread-goal value types, moved from CodexNativeSessionController's nested
// types (2026-07-17).

public enum CodexThreadGoalStatus: String, Sendable, Equatable {
	case active
	case paused
	case budgetLimited
	case complete
}

public struct CodexThreadGoal: Sendable, Equatable {
	public let threadID: String
	public let objective: String
	public let status: CodexThreadGoalStatus
	public let tokenBudget: Int64?
	public let tokensUsed: Int64
	public let timeUsedSeconds: Int64
	public let createdAt: Int64
	public let updatedAt: Int64

	public init(
		threadID: String,
		objective: String,
		status: CodexThreadGoalStatus,
		tokenBudget: Int64?,
		tokensUsed: Int64,
		timeUsedSeconds: Int64,
		createdAt: Int64,
		updatedAt: Int64
	) {
		self.threadID = threadID
		self.objective = objective
		self.status = status
		self.tokenBudget = tokenBudget
		self.tokensUsed = tokensUsed
		self.timeUsedSeconds = timeUsedSeconds
		self.createdAt = createdAt
		self.updatedAt = updatedAt
	}
}
