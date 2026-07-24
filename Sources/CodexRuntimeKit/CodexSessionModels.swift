import Foundation

// Session/thread/turn references and snapshots, moved from
// CodexNativeSessionController's nested types (2026-07-17). The controller
// keeps same-named nested typealiases, so app spellings like
// `CodexNativeSessionController.SessionRef` remain valid.

public struct CodexSessionRef: Sendable, Equatable {
	public var conversationID: String
	public var rolloutPath: String?
	public var model: String?
	public var reasoningEffort: String?

	public init(
		conversationID: String,
		rolloutPath: String?,
		model: String?,
		reasoningEffort: String?
	) {
		self.conversationID = conversationID
		self.rolloutPath = rolloutPath
		self.model = model
		self.reasoningEffort = reasoningEffort
	}
}

public enum CodexTurnStatus: Sendable {
	case completed
	case interrupted
	case failed
}

public struct CodexThreadSnapshot: Sendable, Equatable {
	public enum RuntimeStatus: Sendable, Equatable {
		case notLoaded
		case idle
		case systemError
		case active(activeFlags: [String])

		public var isActive: Bool {
			if case .active = self {
				return true
			}
			return false
		}
	}

	public let conversationID: String
	public let rolloutPath: String?
	public let model: String?
	public let reasoningEffort: String?
	public let runtimeStatus: RuntimeStatus
	public let currentTurnID: String?
	public let activeTurnIDs: [String]
	public let latestTurnStatus: CodexTurnStatus?

	public init(
		conversationID: String,
		rolloutPath: String?,
		model: String?,
		reasoningEffort: String?,
		runtimeStatus: RuntimeStatus,
		currentTurnID: String?,
		activeTurnIDs: [String],
		latestTurnStatus: CodexTurnStatus?
	) {
		self.conversationID = conversationID
		self.rolloutPath = rolloutPath
		self.model = model
		self.reasoningEffort = reasoningEffort
		self.runtimeStatus = runtimeStatus
		self.currentTurnID = currentTurnID
		self.activeTurnIDs = activeTurnIDs
		self.latestTurnStatus = latestTurnStatus
	}

	public var sessionRef: CodexSessionRef {
		CodexSessionRef(
			conversationID: conversationID,
			rolloutPath: rolloutPath,
			model: model,
			reasoningEffort: reasoningEffort
		)
	}

	public var activeFlags: [String] {
		if case let .active(activeFlags) = runtimeStatus {
			return activeFlags
		}
		return []
	}

	public var hasActiveTurn: Bool {
		runtimeStatus.isActive || !activeTurnIDs.isEmpty
	}
}
