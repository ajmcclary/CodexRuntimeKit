import AgentRuntimeKit
import Foundation

/// Server-request method classification, moved from
/// CodexNativeSessionController's private ServerRequestRouting (2026-07-17).
public enum CodexServerRequestRouting: Sendable, Equatable {
	case approval
	case requestUserInput
	case authTokensRefresh
	case mcpElicitation
	case permissions
	case dynamicToolUnsupported
	case unknownUnsupported
}

/// Pure parsing of Codex app-server server-requests: method classification
/// plus approval, permissions, request-user-input, MCP-elicitation, and
/// auth-refresh payload parsing. Moved from CodexNativeSessionController's
/// statics (2026-07-17); bodies unchanged apart from helper qualification and
/// Codex-prefixed types. RepoPrompt policy (MCPIntegrationHelper matching,
/// computer-use auto-approval, response transmission, issue emission) stays
/// app-side.
public enum CodexServerRequestParser {
	public static func classifyMethod(_ method: String) -> CodexServerRequestRouting {
		switch method {
		case "item/tool/requestUserInput":
			return .requestUserInput
		case "account/chatgptAuthTokens/refresh":
			return .authTokensRefresh
		case "mcpServer/elicitation/request":
			return .mcpElicitation
		case "item/permissions/requestApproval":
			return .permissions
		case "item/tool/call":
			return .dynamicToolUnsupported
		case "item/commandExecution/requestApproval",
			"item/fileChange/requestApproval",
			"applyPatchApproval",
			"execCommandApproval":
			return .approval
		default:
			return method.lowercased().contains("requestapproval") ? .approval : .unknownUnsupported
		}
	}
	public static func parseChatgptAuthTokensRefreshRequest(
		requestID: CodexAppServerRequestID,
		params: [String: Any]
	) -> CodexChatgptAuthTokensRefreshRequest? {
		guard let reasonRaw = CodexJSONAccess.firstString(in: params, keys: ["reason"])?
			.trimmingCharacters(in: .whitespacesAndNewlines)
			.lowercased(),
			reasonRaw == "unauthorized" else {
			return nil
		}
		return CodexChatgptAuthTokensRefreshRequest(
			requestID: requestID,
			reason: .unauthorized,
			previousAccountID: CodexJSONAccess.firstString(in: params, keys: ["previousAccountId", "previous_account_id"])
		)
	}
	public static func parseRequestUserInputRequest(
		requestID: CodexAppServerRequestID,
		method: String,
		params: [String: Any],
		activeThreadID: String?,
		currentTurnID: String?
	) -> AgentRequestUserInputRequest? {
		let explicitThreadID = CodexNotificationInterpreter.notificationThreadID(from: params)
			?? CodexJSONAccess.firstString(in: params, keys: ["thread"])
		if let activeThreadID, let explicitThreadID, explicitThreadID != activeThreadID {
			return nil
		}
		guard let threadID = explicitThreadID ?? activeThreadID, !threadID.isEmpty else {
			return nil
		}
		guard let turnID = CodexNotificationInterpreter.notificationTurnID(from: params) ?? currentTurnID,
			!turnID.isEmpty,
			let itemID = CodexNotificationInterpreter.notificationItemID(from: params),
			!itemID.isEmpty,
			let rawQuestions = params["questions"] as? [Any],
			!rawQuestions.isEmpty
		else {
			return nil
		}

		var parsedQuestions: [AgentRequestUserInputQuestion] = []
		var seenQuestionIDs = Set<String>()
		for rawQuestion in rawQuestions {
			guard let question = rawQuestion as? [String: Any] else {
				return nil
			}
			guard let questionID = CodexJSONAccess.firstString(in: question, keys: ["id"]),
				!questionID.isEmpty,
				let header = CodexJSONAccess.firstString(in: question, keys: ["header"]),
				!header.isEmpty,
				let questionText = CodexJSONAccess.firstString(in: question, keys: ["question"]),
				!questionText.isEmpty,
				!seenQuestionIDs.contains(questionID)
			else {
				return nil
			}
			seenQuestionIDs.insert(questionID)

			let rawOptions = question["options"] as? [Any] ?? []
			var options: [AgentRequestUserInputOption] = []
			for rawOption in rawOptions {
				guard let option = rawOption as? [String: Any],
					let label = CodexJSONAccess.firstString(in: option, keys: ["label"]),
					!label.isEmpty,
					let description = CodexJSONAccess.firstString(in: option, keys: ["description"]),
					!description.isEmpty
				else {
					return nil
				}
				options.append(.init(label: label, description: description))
			}

			parsedQuestions.append(
				.init(
					id: questionID,
					header: header,
					question: questionText,
					isOther: CodexJSONAccess.boolScalarValue(from: question["isOther"]) ?? CodexJSONAccess.boolScalarValue(from: question["is_other"]) ?? false,
					isSecret: CodexJSONAccess.boolScalarValue(from: question["isSecret"]) ?? CodexJSONAccess.boolScalarValue(from: question["is_secret"]) ?? false,
					options: options
				)
			)
		}

		return AgentRequestUserInputRequest(
			requestID: requestID,
			method: method,
			threadID: threadID,
			turnID: turnID,
			itemID: itemID,
			questions: parsedQuestions
		)
	}
	public static func parsePermissionsRequest(
		requestID: CodexAppServerRequestID,
		method: String,
		params: [String: Any],
		activeThreadID: String?,
		currentTurnID: String?
	) -> AgentPermissionsRequest? {
		let explicitThreadID = CodexNotificationInterpreter.notificationThreadID(from: params)
			?? CodexJSONAccess.firstString(in: params, keys: ["thread"])
		if let activeThreadID, let explicitThreadID, explicitThreadID != activeThreadID {
			return nil
		}
		guard let threadID = explicitThreadID ?? activeThreadID, !threadID.isEmpty else {
			return nil
		}
		guard let turnID = CodexNotificationInterpreter.notificationTurnID(from: params) ?? currentTurnID,
			!turnID.isEmpty,
			let itemID = CodexNotificationInterpreter.notificationItemID(from: params),
			!itemID.isEmpty,
			let cwd = CodexJSONAccess.firstString(in: params, keys: ["cwd"]),
			!cwd.isEmpty,
			let permissionsObject = CodexJSONAccess.firstJSONObject(in: params, keys: ["permissions"]),
			!permissionsObject.isEmpty,
			let permissionsJSON = CodexJSONAccess.encodeJSONObjectString(permissionsObject)
		else {
			return nil
		}

		let reason = CodexJSONAccess.firstString(in: params, keys: ["reason"])
		let permissionsID = AgentPermissionsRequest.stableID(
			requestID: requestID,
			method: method,
			threadID: threadID,
			turnID: turnID,
			itemID: itemID
		)
		let detailSeed = permissionsID.uuidString
		var details: [AgentApprovalDetail] = []
		var detailIndex = 0
		func appendDetail(label: String, value: String, isCode: Bool = false) {
			details.append(
				AgentApprovalDetail(
					id: AgentApprovalDetail.stableID(
						requestSeed: detailSeed,
						index: detailIndex,
						label: label,
						value: value,
						isCode: isCode
					),
					label: label,
					value: value,
					isCode: isCode
				)
			)
			detailIndex += 1
		}
		appendDetail(label: "Approval Type", value: "permissions")
		appendDetail(label: "Working Directory", value: cwd, isCode: true)
		if let reason, !reason.isEmpty {
			appendDetail(label: "Reason", value: reason)
		}
		appendDetail(label: "Requested Permissions", value: permissionsJSON, isCode: true)

		return AgentPermissionsRequest(
			id: permissionsID,
			requestID: requestID,
			method: method,
			threadID: threadID,
			turnID: turnID,
			itemID: itemID,
			cwd: cwd,
			reason: reason,
			permissionsJSON: permissionsJSON,
			details: details
		)
	}
	public static func parseApprovalRequest(
		requestID: CodexAppServerRequestID,
		method: String,
		params: [String: Any],
		activeThreadID: String?,
		currentTurnID: String?
	) -> AgentApprovalRequest? {
		let explicitThreadID = CodexNotificationInterpreter.notificationThreadID(from: params)
			?? CodexJSONAccess.firstString(in: params, keys: ["thread"])
		if let activeThreadID, let explicitThreadID, explicitThreadID != activeThreadID {
			return nil
		}
		guard let threadID = explicitThreadID ?? activeThreadID, !threadID.isEmpty else {
			return nil
		}

		let explicitTurnID = CodexNotificationInterpreter.notificationTurnID(from: params)
		let turnID =
			explicitTurnID
			?? currentTurnID
			?? "turn:\(requestID.displayValue)"
		let itemID =
			CodexNotificationInterpreter.notificationItemID(from: params)
			?? "item:\(requestID.displayValue)"
		let stableTurnID = explicitTurnID ?? "turn:\(requestID.displayValue)"

		let reason = CodexJSONAccess.firstString(in: params, keys: ["reason", "message", "prompt", "description"])
		let command = CodexJSONAccess.firstString(
			in: params,
			keys: ["command", "cmd", "rawCommand", "raw_command", "shellCommand", "shell_command"]
		)
		?? CodexJSONAccess.firstString(
			in: params,
			keys: ["argv", "args", "exec", "script"]
		)
		let cwd = CodexJSONAccess.firstString(
			in: params,
			keys: ["cwd", "workingDirectory", "working_directory", "workdir", "directory"]
		)
		let grantRoot = CodexJSONAccess.firstString(in: params, keys: ["grantRoot", "grant_root"])
		let proposedExecpolicyAmendmentJSON = CodexJSONAccess.firstJSONString(
			in: params,
			keys: ["proposedExecpolicyAmendment", "proposed_execpolicy_amendment", "execpolicyAmendment", "execpolicy_amendment"]
		)
		let commandActionsJSON = CodexJSONAccess.firstJSONString(
			in: params,
			keys: ["commandActions", "command_actions", "actions"]
		)

		let methodNormalized = CodexJSONAccess.normalizeApprovalKey(method)
		let kind: AgentApprovalKind = {
			if methodNormalized.contains("filechange") || methodNormalized.contains("file_change") {
				return .fileChange
			}
			if methodNormalized.contains("commandexecution") || methodNormalized.contains("command") {
				return .commandExecution
			}
			if command?.isEmpty == false {
				return .commandExecution
			}
			return .fileChange
		}()

		let approvalID = AgentApprovalRequest.stableID(
			requestID: .codex(requestID),
			method: method,
			kind: kind,
			threadID: threadID,
			turnID: stableTurnID,
			itemID: itemID
		)
		let detailSeed = approvalID.uuidString
		var details: [AgentApprovalDetail] = []
		var detailIndex = 0
		func appendDetail(label: String, value: String, isCode: Bool = false) {
			details.append(
				AgentApprovalDetail(
					id: AgentApprovalDetail.stableID(
						requestSeed: detailSeed,
						index: detailIndex,
						label: label,
						value: value,
						isCode: isCode
					),
					label: label,
					value: value,
					isCode: isCode
				)
			)
			detailIndex += 1
		}
		if let reason, !reason.isEmpty {
			appendDetail(label: "Reason", value: reason)
		}
		if let command, !command.isEmpty {
			appendDetail(label: "Command", value: command, isCode: true)
		}
		if let cwd, !cwd.isEmpty {
			appendDetail(label: "Working Directory", value: cwd, isCode: true)
		}
		if let grantRoot, !grantRoot.isEmpty {
			appendDetail(label: "Grant Root", value: grantRoot, isCode: true)
		}
		if let commandActionsJSON, !commandActionsJSON.isEmpty {
			appendDetail(label: "Command Actions", value: commandActionsJSON, isCode: true)
		}
		if let proposedExecpolicyAmendmentJSON, !proposedExecpolicyAmendmentJSON.isEmpty {
			appendDetail(label: "Execpolicy Amendment", value: proposedExecpolicyAmendmentJSON, isCode: true)
		}
		if details.isEmpty {
			appendDetail(label: "Method", value: method, isCode: true)
		}

		return AgentApprovalRequest(
			id: approvalID,
			requestID: .codex(requestID),
			method: method,
			kind: kind,
			threadID: threadID,
			turnID: turnID,
			itemID: itemID,
			reason: reason,
			command: command,
			cwd: cwd,
			grantRoot: grantRoot,
			proposedExecpolicyAmendmentJSON: proposedExecpolicyAmendmentJSON,
			details: details
		)
	}
	public static func parseMCPElicitationRequest(
		requestID: CodexAppServerRequestID,
		method: String,
		params: [String: Any],
		activeThreadID: String?,
		currentTurnID: String?
	) -> AgentMCPElicitationRequest? {
		guard let rawParamsJSON = CodexJSONAccess.encodeJSONObjectString(params) else {
			return nil
		}
		let threadID = CodexNotificationInterpreter.notificationThreadID(from: params)
			?? CodexJSONAccess.firstString(in: params, keys: ["threadId", "thread_id", "thread", "conversationId", "conversation_id"])
			?? activeThreadID
			?? "thread:\(requestID.displayValue)"
		let turnID = CodexNotificationInterpreter.notificationTurnID(from: params)
			?? CodexJSONAccess.firstString(in: params, keys: ["turnId", "turn_id", "turn"])
			?? currentTurnID
			?? "turn:\(requestID.displayValue)"
		let itemID = CodexNotificationInterpreter.notificationItemID(from: params)
			?? CodexJSONAccess.firstString(in: params, keys: ["itemId", "item_id", "item", "callId", "call_id", "invocationId", "invocation_id"])
			?? "item:\(requestID.displayValue)"
		let serverName = CodexJSONAccess.firstString(
			in: params,
			keys: ["server", "serverName", "server_name", "mcpServer", "mcp_server", "mcpServerName", "mcp_server_name"]
		)
		let toolName = CodexJSONAccess.firstString(
			in: params,
			keys: ["tool", "toolName", "tool_name", "name"]
		)
		let title = CodexJSONAccess.firstString(in: params, keys: ["title"])
			?? "MCP Elicitation Requested"
		let prompt = CodexJSONAccess.firstString(in: params, keys: ["prompt", "reason", "description"])
		let message = CodexJSONAccess.firstString(in: params, keys: ["message"])
		let schemaJSON = CodexJSONAccess.firstJSONString(
			in: params,
			keys: ["schema", "contentSchema", "content_schema", "requestedSchema", "requested_schema"]
		)
		let defaultContentJSON = CodexJSONAccess.firstJSONString(
			in: params,
			keys: ["defaultContent", "default_content", "content"]
		)
		let requestSeed = "mcp-elicitation|\(requestID.displayValue)|\(method)|\(threadID)|\(turnID)|\(itemID)"
		var details: [AgentApprovalDetail] = []
		func appendDetail(_ label: String, _ value: String?, isCode: Bool = false) {
			guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return }
			details.append(.init(
				id: AgentApprovalDetail.stableID(
					requestSeed: requestSeed,
					index: details.count,
					label: label,
					value: value,
					isCode: isCode
				),
				label: label,
				value: value,
				isCode: isCode
			))
		}
		appendDetail("Server", serverName)
		appendDetail("Tool", toolName)
		appendDetail("Prompt", prompt ?? message)
		appendDetail("Schema", schemaJSON, isCode: true)
		appendDetail("Default Content", defaultContentJSON, isCode: true)
		appendDetail("Raw Request", rawParamsJSON, isCode: true)
		return AgentMCPElicitationRequest(
			requestID: requestID,
			method: method,
			threadID: threadID,
			turnID: turnID,
			itemID: itemID,
			serverName: serverName,
			toolName: toolName,
			title: title,
			prompt: prompt,
			message: message,
			schemaJSON: schemaJSON,
			defaultContentJSON: defaultContentJSON,
			rawParamsJSON: rawParamsJSON,
			details: details
		)
	}
}
