import AgentRuntimeKit
import Foundation

// The neutral Codex runtime event stream vocabulary, moved from
// CodexNativeSessionController's nested types (2026-07-17). Payload types are
// AgentRuntimeCore user-interaction models plus the neutral value types in
// this module; nothing here references the controller, MCP services, or
// view models.

public struct CodexReasoningDeltaPayload: Sendable, Equatable {
	public enum Kind: Sendable, Equatable {
		case summary
		case text
	}

	public let text: String
	public let kind: Kind
	public let itemID: String?
	public let groupID: String?
	public let index: Int?

	public init(
		text: String,
		kind: Kind,
		itemID: String?,
		groupID: String?,
		index: Int?
	) {
		self.text = text
		self.kind = kind
		self.itemID = itemID
		self.groupID = groupID
		self.index = index
	}
}

public struct CodexCommandExecutionRunningUpdate: Sendable {
	public let invocationID: UUID?
	public let processID: String?
	public let appendedOutput: String?
	public let sealsAssistantBoundary: Bool

	public init(
		invocationID: UUID?,
		processID: String?,
		appendedOutput: String?,
		sealsAssistantBoundary: Bool = false
	) {
		self.invocationID = invocationID
		self.processID = processID
		self.appendedOutput = appendedOutput
		self.sealsAssistantBoundary = sealsAssistantBoundary
	}
}

public struct CodexLivenessActivity: Sendable, Equatable {
	public enum Kind: String, Sendable, Equatable {
		case threadStatusChanged = "thread-status-changed"
		case turnPlanUpdated = "turn-plan-updated"
		case turnDiffUpdated = "turn-diff-updated"
		case itemPlanDelta = "item-plan-delta"
		case mcpToolProgress = "mcp-tool-progress"
		case commandOrProcessOutput = "command-or-process-output"
		case processExited = "process-exited"
		case hookLifecycle = "hook-lifecycle"
		case warning
		case deprecationNotice = "deprecation-notice"
		case serverRequestResolved = "server-request-resolved"
		case unknownScoped = "unknown-scoped"
	}

	public let kind: Kind
	public let method: String
	public let threadID: String?
	public let turnID: String?
	public let itemID: String?
	public let activeFlags: [String]
	public let message: String?

	public init(
		kind: Kind,
		method: String,
		threadID: String?,
		turnID: String?,
		itemID: String?,
		activeFlags: [String],
		message: String?
	) {
		self.kind = kind
		self.method = method
		self.threadID = threadID
		self.turnID = turnID
		self.itemID = itemID
		self.activeFlags = activeFlags
		self.message = message
	}
}

public struct CodexErrorNotification: Sendable, Equatable {
	public let message: String
	public let willRetry: Bool
	public let threadID: String?
	public let turnID: String?

	public init(
		message: String,
		willRetry: Bool,
		threadID: String?,
		turnID: String?
	) {
		self.message = message
		self.willRetry = willRetry
		self.threadID = threadID
		self.turnID = turnID
	}
}

public enum CodexRuntimeEvent: Sendable {
	case assistantDelta(String)
	case reasoningDelta(CodexReasoningDeltaPayload)
	case tokenUsage(AgentContextUsage)
	case turnStarted(turnID: String?)
	case turnCompleted(turnID: String?, status: CodexTurnStatus)
	case contextCompacted(turnID: String?)
	case approvalRequest(AgentApprovalRequest)
	case permissionsRequest(AgentPermissionsRequest)
	case requestUserInput(AgentRequestUserInputRequest)
	case mcpElicitationRequest(AgentMCPElicitationRequest)
	case serverRequestIssue(CodexServerRequestIssue)
	case toolCall(name: String, invocationID: UUID?, argsJSON: String?)
	case toolResult(name: String, invocationID: UUID?, argsJSON: String?, resultJSON: String, isError: Bool?)
	case commandExecutionRunning(CodexCommandExecutionRunningUpdate)
	case livenessActivity(CodexLivenessActivity)
	case errorNotification(CodexErrorNotification)
	case error(String)
	case system(String)
}
