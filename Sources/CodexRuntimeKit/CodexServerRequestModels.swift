import AgentRuntimeKit
import Foundation

// Server-request issue + auth-refresh message types, moved from
// CodexNativeSessionController's nested types (2026-07-17).

public struct CodexServerRequestIssue: Sendable, Equatable {
	public enum Kind: String, Sendable, Equatable {
		case authTokensRefreshInvalidParams = "auth-tokens-refresh-invalid-params"
		case authTokensRefreshUnavailable = "auth-tokens-refresh-unavailable"
		case authTokensRefreshFailed = "auth-tokens-refresh-failed"
		case requestUserInputInvalidParams = "request-user-input-invalid-params"
		case mcpElicitationInvalidParams = "mcp-elicitation-invalid-params"
		case mcpElicitationUnsupported = "mcp-elicitation-unsupported"
		case permissionsRequestUnsupported = "permissions-request-unsupported"
		case dynamicToolCallUnsupported = "dynamic-tool-call-unsupported"
		case unsupportedMethod = "unsupported-method"
	}

	public let requestID: CodexAppServerRequestID
	public let method: String
	public let kind: Kind
	public let message: String

	public init(
		requestID: CodexAppServerRequestID,
		method: String,
		kind: Kind,
		message: String
	) {
		self.requestID = requestID
		self.method = method
		self.kind = kind
		self.message = message
	}
}

public struct CodexChatgptAuthTokensRefreshRequest: Sendable, Equatable {
	public enum Reason: Sendable, Equatable {
		case unauthorized
	}

	public let requestID: CodexAppServerRequestID
	public let reason: Reason
	public let previousAccountID: String?

	public init(
		requestID: CodexAppServerRequestID,
		reason: Reason,
		previousAccountID: String?
	) {
		self.requestID = requestID
		self.reason = reason
		self.previousAccountID = previousAccountID
	}
}

public struct CodexChatgptAuthTokensRefreshResponse: Sendable, Equatable {
	public let accessToken: String
	public let chatgptAccountID: String
	public let chatgptPlanType: String?

	public init(
		accessToken: String,
		chatgptAccountID: String,
		chatgptPlanType: String?
	) {
		self.accessToken = accessToken
		self.chatgptAccountID = chatgptAccountID
		self.chatgptPlanType = chatgptPlanType
	}

	public var payload: [String: Any] {
		var result: [String: Any] = [
			"accessToken": accessToken,
			"chatgptAccountId": chatgptAccountID
		]
		if let chatgptPlanType {
			result["chatgptPlanType"] = chatgptPlanType
		}
		return result
	}
}

public typealias CodexChatgptAuthTokensRefreshHandler = @Sendable (CodexChatgptAuthTokensRefreshRequest) async throws -> CodexChatgptAuthTokensRefreshResponse
