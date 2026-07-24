import AgentRuntimeKit
import Foundation

// Neutral Codex app-server protocol vocabulary, promoted verbatim from the
// app-side client's nested types (2026-07-17). Process/transport ownership
// (launch config, PID registration, byte channels, liveness) deliberately
// stays app-side.

public struct CodexRemoteReasoningEffort: Sendable, Hashable {
	public let reasoningEffort: String
	public let description: String

	public init(reasoningEffort: String, description: String) {
		self.reasoningEffort = reasoningEffort
		self.description = description
	}
}

/// Server-recommended migration metadata carried on a catalog entry
/// (`model/list` `upgradeInfo`). Advisory only — used for client migration
/// prompts, never for automatic substitution.
public struct CodexRemoteModelUpgradeInfo: Sendable, Hashable {
	public let model: String
	public let upgradeCopy: String?
	public let migrationMarkdown: String?
	public let modelLink: String?

	public init(model: String, upgradeCopy: String?, migrationMarkdown: String?, modelLink: String?) {
		self.model = model
		self.upgradeCopy = upgradeCopy
		self.migrationMarkdown = migrationMarkdown
		self.modelLink = modelLink
	}
}

public struct CodexRemoteModel: Sendable, Hashable {
	public let id: String
	public let model: String
	public let displayName: String
	public let description: String
	/// The catalog default for an UNSPECIFIED selection — never a fallback
	/// for a failed explicit selection.
	public let isDefault: Bool
	public let supportedReasoningEfforts: [CodexRemoteReasoningEffort]
	public let defaultReasoningEffort: String?
	/// Service-tier identifiers this model advertises (for carry-forward
	/// validation on upgrade recommendations).
	public let serviceTierIDs: [String]
	/// `model/list` `upgrade`: the recommended successor's model id, when
	/// the server marks this entry as superseded. Advisory metadata only.
	public let upgradeModelID: String?
	public let upgradeInfo: CodexRemoteModelUpgradeInfo?

	public init(
		id: String,
		model: String,
		displayName: String,
		description: String,
		isDefault: Bool,
		supportedReasoningEfforts: [CodexRemoteReasoningEffort],
		defaultReasoningEffort: String?,
		serviceTierIDs: [String] = [],
		upgradeModelID: String? = nil,
		upgradeInfo: CodexRemoteModelUpgradeInfo? = nil
	) {
		self.id = id
		self.model = model
		self.displayName = displayName
		self.description = description
		self.isDefault = isDefault
		self.supportedReasoningEfforts = supportedReasoningEfforts
		self.defaultReasoningEffort = defaultReasoningEffort
		self.serviceTierIDs = serviceTierIDs
		self.upgradeModelID = upgradeModelID
		self.upgradeInfo = upgradeInfo
	}
}

/// An inbound JSON-RPC notification envelope (method + typed params).
public struct CodexServerNotification: Sendable {
	public let method: String
	public let params: [String: CodexJSONValue]

	public init(method: String, params: [String: CodexJSONValue]) {
		self.method = method
		self.params = params
	}
}

/// An inbound JSON-RPC server→client request envelope.
public struct CodexServerRequest: Sendable {
	public let id: CodexAppServerRequestID
	public let method: String
	public let params: [String: CodexJSONValue]

	public init(id: CodexAppServerRequestID, method: String, params: [String: CodexJSONValue]) {
		self.id = id
		self.method = method
		self.params = params
	}
}

public enum CodexClientError: Error, LocalizedError {
	case processNotRunning
	case invalidResponse
	case jsonDecodeFailed
	case requestFailed(String)
	case rpcError(code: Int, message: String)
	case executableUnavailable(String)
	case transportWriteFailed(message: String, errno: Int32?)
	case transportReadSetupFailed(message: String, errno: Int32?)
	/// Fail-closed refusal: the request needs an experimental requirement the
	/// current transport was not admitted with. Raised client-side before any
	/// bytes cross the wire.
	case experimentalRequirementNotAdmitted(method: String, requirement: String)

	public var errorDescription: String? {
		switch self {
		case .processNotRunning:
			return "Codex app-server process is not running."
		case .invalidResponse:
			return "Codex app-server returned an invalid response."
		case .jsonDecodeFailed:
			return "Failed to decode Codex app-server JSON response."
		case .requestFailed(let message):
			return message
		case .rpcError(_, let message):
			return message
		case .executableUnavailable(let message):
			return message
		case .transportWriteFailed(let message, _):
			return message
		case .transportReadSetupFailed(let message, _):
			return message
		case .experimentalRequirementNotAdmitted(let method, let requirement):
			return "Codex request \(method) requires the experimental capability \(requirement), but this transport was initialized stable-only."
		}
	}
}

public enum CodexTransportTerminationReason: Sendable, Equatable {
	case stdinWrite(method: String?, errno: Int32?)
	case stdoutEOF
	case timeout(method: String, requestID: String)
	case explicitStop
	case livenessCheckFailed(method: String?)
	case decodeRecoveryBudgetExceeded(generation: UInt64)
	case readSourceSetupFailed(stream: String, errno: Int32?)
}

/// Neutral timeout classification + poisoning policy for the app-server
/// request surface.
public enum CodexRequestTimeoutPolicy {
	public static func isTimeoutError(_ error: Error) -> Bool {
		if let clientError = error as? CodexClientError,
			case .requestFailed(let message) = clientError {
			return isTimeoutErrorMessage(message)
		}

		let nsError = error as NSError
		let candidates = [
			error.localizedDescription,
			nsError.localizedFailureReason,
			nsError.localizedRecoverySuggestion
		].compactMap { $0 }
		return candidates.contains(where: isTimeoutErrorMessage)
	}

	static func isTimeoutErrorMessage(_ message: String) -> Bool {
		let normalized = message
			.trimmingCharacters(in: .whitespacesAndNewlines)
			.lowercased()
		guard !normalized.isEmpty else { return false }
		return normalized.contains("request timed out after")
			|| normalized.contains("timed out after")
	}

	/// Control-plane methods whose timeout poisons the transport.
	public static func shouldPoisonTransportOnTimeout(method: String) -> Bool {
		switch method {
		case "thread/start", "thread/resume":
			return true
		default:
			return false
		}
	}
}
