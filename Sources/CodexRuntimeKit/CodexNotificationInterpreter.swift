import AgentRuntimeKit
import Foundation

/// The pure-decision result of notification routing: whether to drop, plus the
/// verbatim debug line the caller may log. At most one debug line is produced
/// per decision (allow-lines always precede a final "keep" result).
public struct CodexNotificationRoutingDecision: Sendable, Equatable {
	public let shouldDrop: Bool
	public let debugDescription: String?

	public init(shouldDrop: Bool, debugDescription: String?) {
		self.shouldDrop = shouldDrop
		self.debugDescription = debugDescription
	}
}

/// Thrown by thread-goal projection when the payload is malformed. The
/// controller maps this to its client's invalid-response error to preserve the
/// established error surface.
public enum CodexThreadGoalParseError: Error, Sendable, Equatable {
	case invalidResponse
}

/// Pure interpretation of Codex app-server notifications: envelope IDs,
/// routing decisions, liveness/error/token-usage parsing, turn status, and
/// thread snapshot/goal projection. Moved from CodexNativeSessionController's
/// statics (2026-07-17); bodies unchanged apart from JSON-helper qualification,
/// Codex-prefixed type names, and the routing decision returning its debug
/// line instead of logging. Takes wire payloads, returns typed values —
/// nothing here touches the controller, MCP services, or view models.
public enum CodexNotificationInterpreter {
	// MARK: - Envelope identifiers

	public static func notificationThreadID(from params: [String: Any]) -> String? {
		let threadIDKeys = ["threadId", "thread_id", "threadID", "conversationId", "conversation_id"]
		for candidate in notificationEnvelopeDictionaries(from: params) {
			if let threadID = CodexJSONAccess.firstString(in: candidate, keys: threadIDKeys) {
				return threadID
			}
			if let threadID = CodexJSONAccess.stringScalarValue(from: candidate["thread"]) {
				return threadID
			}
			if let turn = candidate["turn"] as? [String: Any],
				let threadID = CodexJSONAccess.firstString(in: turn, keys: threadIDKeys) {
				return threadID
			}
			if let thread = candidate["thread"] as? [String: Any],
				let threadID = CodexJSONAccess.firstString(in: thread, keys: ["id"] + threadIDKeys) {
				return threadID
			}
		}
		return nil
	}

	public static func notificationTurnID(from params: [String: Any]) -> String? {
		let turnIDKeys = ["turnId", "turn_id", "turnID"]
		for candidate in notificationEnvelopeDictionaries(from: params) {
			if let turnID = CodexJSONAccess.firstString(in: candidate, keys: turnIDKeys) {
				return turnID
			}
			if let turnID = CodexJSONAccess.stringScalarValue(from: candidate["turn"]) {
				return turnID
			}
			if let turn = candidate["turn"] as? [String: Any],
				let turnID = CodexJSONAccess.firstString(in: turn, keys: ["id"] + turnIDKeys) {
				return turnID
			}
		}
		guard let message = params["msg"] as? [String: Any],
			let messageType = (message["type"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
			messageType == "agent_message" || messageType == "task_complete" || messageType == "task_started"
		else {
			return nil
		}
		if let rawID = params["id"],
			let topLevelID = CodexJSONAccess.stringScalarValue(from: rawID) {
			return topLevelID
		}
		return CodexJSONAccess.firstString(in: params, keys: ["id"])
	}

	public static func notificationItemID(from params: [String: Any]) -> String? {
		let itemIDKeys = ["id", "itemId", "item_id", "itemID", "callId", "call_id", "invocationId", "invocation_id"]
		for candidate in notificationEnvelopeDictionaries(from: params) {
			if let item = candidate["item"] as? [String: Any],
				let itemID = CodexJSONAccess.firstString(in: item, keys: itemIDKeys) {
				return itemID
			}
			if let request = candidate["request"] as? [String: Any] {
				if let item = request["item"] as? [String: Any],
					let itemID = CodexJSONAccess.firstString(in: item, keys: itemIDKeys) {
					return itemID
				}
				if let itemID = CodexJSONAccess.firstString(
					in: request,
					keys: ["itemId", "item_id", "itemID", "callId", "call_id", "invocationId", "invocation_id"]
				) {
					return itemID
				}
			}
			if let itemID = CodexJSONAccess.firstString(
				in: candidate,
				keys: ["itemId", "item_id", "itemID", "callId", "call_id", "invocationId", "invocation_id"]
			) {
				return itemID
			}
			if let itemID = CodexJSONAccess.stringScalarValue(from: candidate["item"]) {
				return itemID
			}
		}
		return CodexJSONAccess.stringScalarValue(from: params["id"])
	}

	public static func notificationEnvelopeDictionaries(from params: [String: Any]) -> [[String: Any]] {
		var result: [[String: Any]] = [params]
		let envelopeKeys = ["payload", "event", "request", "error", "msg"]
		for key in envelopeKeys {
			if let object = params[key] as? [String: Any] {
				result.append(object)
				for nestedKey in envelopeKeys where nestedKey != key {
					if let nested = object[nestedKey] as? [String: Any] {
						result.append(nested)
					}
				}
			}
		}
		return result
	}

	public static func assistantMessageText(from params: [String: Any]) -> String? {
		if let msg = params["msg"] as? [String: Any],
			let message = msg["message"] as? String {
			let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
			return trimmed.isEmpty ? nil : message
		}
		if let message = params["message"] as? String {
			let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
			return trimmed.isEmpty ? nil : message
		}
		return nil
	}

	public static func toolItemCandidates(fromParams params: [String: Any]) -> [[String: Any]] {
		var candidates: [[String: Any]] = []
		if let item = params["item"] as? [String: Any] {
			candidates.append(item)
		}
		if let msg = params["msg"] as? [String: Any] {
			if let item = msg["item"] as? [String: Any] {
				candidates.append(item)
			}
			candidates.append(msg)
		}
		if let payload = params["payload"] as? [String: Any] {
			if let item = payload["item"] as? [String: Any] {
				candidates.append(item)
			}
			candidates.append(payload)
		}
		if let event = params["event"] as? [String: Any] {
			if let item = event["item"] as? [String: Any] {
				candidates.append(item)
			}
			candidates.append(event)
		}
		candidates.append(params)
		return candidates
	}

	public static func normalizedExternalToolName(_ raw: String?) -> String? {
		guard let raw else { return nil }
		let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !trimmed.isEmpty else { return nil }
		let lowered = trimmed.lowercased()
		let suffix = lowered.split(separator: ".").last.map(String.init) ?? lowered
		if suffix == "local_shell" || suffix == "shell" || suffix == "unified_exec" || suffix == "exec_command" || suffix == "run_shell_command" {
			return "bash"
		}
		if suffix == "filechange" || suffix == "file_change" {
			return "apply_patch"
		}
		return suffix
	}

	// MARK: - Method classification

	public static func isTurnOrItemScopedNotificationMethod(_ method: String) -> Bool {
		let lowerMethod = method.lowercased()
		return method == "turn/started"
			|| method == "turn/completed"
			|| method == "codex/event/task_started"
			|| method == "codex/event/task_complete"
			|| lowerMethod.hasPrefix("turn/")
			|| lowerMethod.hasPrefix("item/")
			|| lowerMethod.hasPrefix("command/")
			|| lowerMethod.hasPrefix("process/")
			|| lowerMethod.hasPrefix("hook/")
			|| lowerMethod.hasPrefix("codex/event/item_")
			|| lowerMethod.hasPrefix("codex/event/turn_")
	}

	public static func isTurnLifecycleNotificationMethod(_ method: String) -> Bool {
		method == "turn/started"
			|| method == "turn/completed"
			|| method == "codex/event/turn_started"
			|| method == "codex/event/turn_completed"
			|| method == "codex/event/task_started"
			|| method == "codex/event/task_complete"
	}

	public static func isTurnActivityNotificationMethod(_ method: String) -> Bool {
		if isTurnLifecycleNotificationMethod(method) {
			return false
		}
		if method == "codex/event/task_started" {
			return true
		}
		if method == "codex/event/task_complete" {
			return false
		}
		let lowerMethod = method.lowercased()
		if lowerMethod.hasPrefix("turn/")
			|| lowerMethod.hasPrefix("item/")
			|| lowerMethod.hasPrefix("command/")
			|| lowerMethod.hasPrefix("process/")
			|| lowerMethod.hasPrefix("hook/")
			|| lowerMethod.hasPrefix("codex/event/item_")
			|| lowerMethod.hasPrefix("codex/event/turn_") {
			return true
		}
		if method.hasPrefix("codex/event/agent_message")
			|| method.hasPrefix("codex/event/reasoning_")
			|| method.hasPrefix("codex/event/agent_reasoning") {
			return true
		}
		if lowerMethod.contains("exec_command") {
			return true
		}
		return false
	}

	public static func shouldPromoteCurrentTurn(
		method: String,
		notifiedTurnID: String,
		currentTurnID: String?
	) -> Bool {
		guard isTurnActivityNotificationMethod(method) else {
			return false
		}
		return currentTurnID != notifiedTurnID
	}

	// MARK: - Routing decision

	public static func routingDecision(
		method: String,
		params: [String: Any],
		activeThreadID: String,
		currentTurnID: String?,
		activeTurnIDs: Set<String>
	) -> CodexNotificationRoutingDecision {
		let isTurnOrItemScoped = isTurnOrItemScopedNotificationMethod(method)
		let isTurnLifecycleMethod = isTurnLifecycleNotificationMethod(method)
		let isStreamingItemRelated = isStreamingItemRelatedNotification(method: method, params: params)
		let hasStrongStreamingCorrelation = isStreamingItemRelated
			&& hasStrongStreamingItemCorrelation(method: method, params: params)
		let notifiedThreadID = notificationThreadID(from: params)
		if let notifiedThreadID, notifiedThreadID != activeThreadID {
			return CodexNotificationRoutingDecision(
				shouldDrop: true,
				debugDescription: "[CodexNativeController] dropNotification method=\(method) reason=thread-mismatch activeThreadID=\(activeThreadID) notifiedThreadID=\(notifiedThreadID)"
			)
		}
		if isTurnOrItemScoped, isTurnLifecycleMethod {
			return CodexNotificationRoutingDecision(shouldDrop: false, debugDescription: nil)
		}

		let notifiedTurnID = notificationTurnID(from: params)
		if isTurnOrItemScoped,
			!isTurnLifecycleMethod,
			let notifiedTurnID {
			if !activeTurnIDs.isEmpty {
				if !activeTurnIDs.contains(notifiedTurnID) {
					if hasStrongStreamingCorrelation {
						return CodexNotificationRoutingDecision(
							shouldDrop: false,
							debugDescription: "[CodexNativeController] allowNotification method=\(method) reason=turn-not-active-streaming-item activeTurnIDs=\(Array(activeTurnIDs).joined(separator: ",")) notifiedTurnID=\(notifiedTurnID)"
						)
					} else if isStreamingItemRelated {
						return CodexNotificationRoutingDecision(
							shouldDrop: true,
							debugDescription: "[CodexNativeController] dropNotification method=\(method) reason=turn-not-active-streaming-item-weak-correlation activeTurnIDs=\(Array(activeTurnIDs).joined(separator: ",")) notifiedTurnID=\(notifiedTurnID)"
						)
					} else {
						return CodexNotificationRoutingDecision(
							shouldDrop: true,
							debugDescription: "[CodexNativeController] dropNotification method=\(method) reason=turn-not-active activeTurnIDs=\(Array(activeTurnIDs).joined(separator: ",")) notifiedTurnID=\(notifiedTurnID)"
						)
					}
				}
			} else if let currentTurnID,
				notifiedTurnID != currentTurnID {
				if hasStrongStreamingCorrelation {
					return CodexNotificationRoutingDecision(
						shouldDrop: false,
						debugDescription: "[CodexNativeController] allowNotification method=\(method) reason=turn-mismatch-streaming-item activeTurnID=\(currentTurnID) notifiedTurnID=\(notifiedTurnID)"
					)
				} else if isStreamingItemRelated {
					return CodexNotificationRoutingDecision(
						shouldDrop: true,
						debugDescription: "[CodexNativeController] dropNotification method=\(method) reason=turn-mismatch-streaming-item-weak-correlation activeTurnID=\(currentTurnID) notifiedTurnID=\(notifiedTurnID)"
					)
				} else {
					return CodexNotificationRoutingDecision(
						shouldDrop: true,
						debugDescription: "[CodexNativeController] dropNotification method=\(method) reason=turn-mismatch activeTurnID=\(currentTurnID) notifiedTurnID=\(notifiedTurnID)"
					)
				}
			}
		}

		if notifiedThreadID == nil,
			notifiedTurnID == nil,
			activeTurnIDs.isEmpty,
			currentTurnID == nil,
			isTurnOrItemScoped {
			if hasStrongStreamingCorrelation {
				return CodexNotificationRoutingDecision(
					shouldDrop: false,
					debugDescription: "[CodexNativeController] allowNotification method=\(method) reason=unscoped-streaming-item-without-active-turn activeThreadID=\(activeThreadID)"
				)
			} else if isStreamingItemRelated {
				return CodexNotificationRoutingDecision(
					shouldDrop: true,
					debugDescription: "[CodexNativeController] dropNotification method=\(method) reason=unscoped-streaming-item-weak-correlation activeThreadID=\(activeThreadID)"
				)
			} else {
				return CodexNotificationRoutingDecision(
					shouldDrop: true,
					debugDescription: "[CodexNativeController] dropNotification method=\(method) reason=unscoped-without-active-turn activeThreadID=\(activeThreadID)"
				)
			}
		}

		return CodexNotificationRoutingDecision(shouldDrop: false, debugDescription: nil)
	}

	// MARK: - Streaming-item correlation

	public static func isStreamingItemRelatedNotification(
		method: String,
		params: [String: Any]
	) -> Bool {
		let lowerMethod = method.lowercased()
		if lowerMethod.contains("commandexecution")
			|| lowerMethod.contains("command_execution")
			|| lowerMethod.contains("exec_command")
			|| lowerMethod.contains("filechange")
			|| lowerMethod.contains("file_change") {
			return true
		}
		for candidate in toolItemCandidates(fromParams: params) {
			if candidateLooksLikeCommandExecution(candidate) || candidateLooksLikeFileChange(candidate) {
				return true
			}
		}
		return false
	}

	public static func hasStrongStreamingItemCorrelation(
		method: String,
		params: [String: Any]
	) -> Bool {
		let lowerMethod = method.lowercased()
		let methodIndicatesStreamingItem =
			lowerMethod.contains("commandexecution")
			|| lowerMethod.contains("command_execution")
			|| lowerMethod.contains("exec_command")
			|| lowerMethod.contains("filechange")
			|| lowerMethod.contains("file_change")
		for candidate in toolItemCandidates(fromParams: params) {
			let candidateIsStreamingItem = methodIndicatesStreamingItem
				|| candidateLooksLikeCommandExecution(candidate)
				|| candidateLooksLikeFileChange(candidate)
			guard candidateIsStreamingItem else { continue }
			if hasCommandCorrelationID(in: candidate, allowGenericID: true) {
				return true
			}
		}
		return false
	}

	public static func hasCommandCorrelationID(
		in candidate: [String: Any],
		allowGenericID: Bool
	) -> Bool {
		if CodexJSONAccess.firstString(
			in: candidate,
			keys: [
				"callId", "call_id", "itemId", "item_id", "invocationId", "invocation_id",
				"toolCallId", "tool_call_id"
			]
		) != nil {
			return true
		}
		if allowGenericID,
			let genericID = CodexJSONAccess.firstString(in: candidate, keys: ["id"]),
			!genericID.isEmpty {
			return true
		}
		return false
	}

	public static func candidateLooksLikeCommandExecution(_ candidate: [String: Any]) -> Bool {
		let typeRaw = CodexJSONAccess.firstString(in: candidate, keys: ["type", "itemType", "item_type"])?
			.trimmingCharacters(in: .whitespacesAndNewlines)
			.lowercased() ?? ""
		if typeRaw.contains("commandexecution") || typeRaw.contains("command_execution") {
			return true
		}

		let toolName = CodexJSONAccess.firstString(
			in: candidate,
			keys: ["name", "toolName", "tool_name", "functionName", "function_name", "callName", "call_name"]
		)
		if normalizedExternalToolName(toolName) == "bash" {
			return true
		}
		return false
	}

	public static func candidateLooksLikeFileChange(_ candidate: [String: Any]) -> Bool {
		let typeRaw = CodexJSONAccess.firstString(in: candidate, keys: ["type", "itemType", "item_type"])?
			.trimmingCharacters(in: .whitespacesAndNewlines)
			.lowercased() ?? ""
		return typeRaw.contains("filechange") || typeRaw.contains("file_change")
	}

	// MARK: - Errors and liveness

	public static func parseErrorNotification(from params: [String: Any]) -> CodexErrorNotification? {
		let errorObject = CodexJSONAccess.firstJSONObject(in: params, keys: ["error"]) ?? params
		guard let message = CodexJSONAccess.firstString(
			in: errorObject,
			keys: ["message", "errorMessage", "error_message", "detail", "description"]
		) ?? CodexJSONAccess.firstString(
			in: params,
			keys: ["message", "errorMessage", "error_message", "detail", "description"]
		) else {
			return nil
		}
		let willRetry = CodexJSONAccess.boolScalarValue(from: errorObject["willRetry"])
			?? CodexJSONAccess.boolScalarValue(from: errorObject["will_retry"])
			?? CodexJSONAccess.boolScalarValue(from: params["willRetry"])
			?? CodexJSONAccess.boolScalarValue(from: params["will_retry"])
			?? false
		let threadID = notificationThreadID(from: params)
			?? CodexJSONAccess.firstString(in: errorObject, keys: ["threadId", "thread_id", "threadID", "conversationId", "conversation_id"])
		let turnID = notificationTurnID(from: params)
			?? CodexJSONAccess.firstString(in: errorObject, keys: ["turnId", "turn_id", "turnID"])
		return CodexErrorNotification(
			message: message,
			willRetry: willRetry,
			threadID: threadID,
			turnID: turnID
		)
	}

	public static func parseLivenessActivity(method: String, params: [String: Any]) -> CodexLivenessActivity? {
		guard let kind = livenessActivityKind(for: method, params: params) else { return nil }
		return CodexLivenessActivity(
			kind: kind,
			method: method,
			threadID: notificationThreadID(from: params),
			turnID: notificationTurnID(from: params),
			itemID: notificationItemID(from: params),
			activeFlags: notificationActiveFlags(from: params),
			message: livenessActivityMessage(from: params)
		)
	}

	public static func livenessActivityKind(for method: String, params: [String: Any]) -> CodexLivenessActivity.Kind? {
		switch method {
		case "thread/status/changed":
			return .threadStatusChanged
		case "turn/plan/updated":
			return .turnPlanUpdated
		case "turn/diff/updated":
			return .turnDiffUpdated
		case "item/plan/delta":
			return .itemPlanDelta
		case "item/mcpToolCall/progress", "item/mcp_tool_call/progress":
			return .mcpToolProgress
		case "command/exec/outputDelta", "command/exec/output_delta", "process/outputDelta", "process/output_delta":
			return .commandOrProcessOutput
		case "process/exited":
			return .processExited
		case "hook/started", "hook/completed":
			return .hookLifecycle
		case "warning":
			return .warning
		case "deprecationNotice", "deprecation_notice":
			return .deprecationNotice
		case "serverRequest/resolved", "server_request/resolved":
			return .serverRequestResolved
		default:
			guard isTurnOrItemScopedNotificationMethod(method),
				notificationThreadID(from: params) != nil
					|| notificationTurnID(from: params) != nil
					|| notificationItemID(from: params) != nil else {
				return nil
			}
			return .unknownScoped
		}
	}

	public static func notificationActiveFlags(from params: [String: Any]) -> [String] {
		let candidates = notificationEnvelopeDictionaries(from: params)
		for candidate in candidates {
			if let status = candidate["status"] {
				let parsed = parseThreadRuntimeStatus(from: status)
				if case .active(let activeFlags) = parsed, !activeFlags.isEmpty {
					return activeFlags
				}
			}
			if let thread = candidate["thread"] as? [String: Any], let status = thread["status"] {
				let parsed = parseThreadRuntimeStatus(from: status)
				if case .active(let activeFlags) = parsed, !activeFlags.isEmpty {
					return activeFlags
				}
			}
			let flags = ((candidate["activeFlags"] ?? candidate["active_flags"]) as? [Any] ?? [])
				.compactMap { CodexJSONAccess.stringScalarValue(from: $0) }
			if !flags.isEmpty {
				return flags
			}
		}
		return []
	}

	public static func livenessActivityMessage(from params: [String: Any]) -> String? {
		CodexJSONAccess.firstString(
			in: params,
			keys: ["message", "warning", "text", "reason", "description", "detail"]
		)
	}

	// MARK: - Token usage

	public static func parseTokenUsagePayload(from params: [String: Any]) -> AgentContextUsage? {
		let tokenUsage = tokenUsageObject(from: params)
		guard let tokenUsage else { return nil }

		let last = usageBreakdown(
			in: tokenUsage,
			keys: ["last", "lastTokenUsage", "last_token_usage"]
		)
		let total = usageBreakdown(
			in: tokenUsage,
			keys: ["total", "totalTokenUsage", "total_token_usage"]
		)
		let lastTotal = usageTotalTokens(from: last)
		let totalTotal = usageTotalTokens(from: total)
		let contextWindow =
			CodexJSONAccess.intValue(tokenUsage["modelContextWindow"])
			?? CodexJSONAccess.intValue(tokenUsage["model_context_window"])
			?? CodexJSONAccess.intValue(tokenUsage["contextWindow"])
			?? CodexJSONAccess.intValue(tokenUsage["context_window"])

		guard contextWindow != nil || lastTotal != nil || totalTotal != nil else {
			return nil
		}
		return AgentContextUsage(
			modelContextWindow: contextWindow,
			lastTotalTokens: lastTotal,
			totalTotalTokens: totalTotal
		)
	}

	public static func tokenUsageObject(from params: [String: Any]) -> [String: Any]? {
		if let tokenUsage = params["tokenUsage"] as? [String: Any] {
			return tokenUsage
		}
		if let tokenUsage = params["token_usage"] as? [String: Any] {
			return tokenUsage
		}
		let hasTokenUsageShape =
			params["last"] != nil
			|| params["total"] != nil
			|| params["lastTokenUsage"] != nil
			|| params["last_token_usage"] != nil
			|| params["totalTokenUsage"] != nil
			|| params["total_token_usage"] != nil
			|| params["modelContextWindow"] != nil
			|| params["model_context_window"] != nil
		return hasTokenUsageShape ? params : nil
	}

	public static func usageBreakdown(
		in tokenUsage: [String: Any],
		keys: [String]
	) -> [String: Any]? {
		for key in keys {
			if let value = tokenUsage[key] as? [String: Any] {
				return value
			}
		}
		return nil
	}

	public static func usageTotalTokens(from usage: [String: Any]?) -> Int? {
		guard let usage else { return nil }

		if let explicit =
			CodexJSONAccess.intValue(usage["totalTokens"])
			?? CodexJSONAccess.intValue(usage["total_tokens"])
			?? CodexJSONAccess.intValue(usage["tokenCount"])
			?? CodexJSONAccess.intValue(usage["token_count"]) {
			return explicit
		}

		let input = CodexJSONAccess.intValue(usage["inputTokens"]) ?? CodexJSONAccess.intValue(usage["input_tokens"])
		let cachedInput = CodexJSONAccess.intValue(usage["cachedInputTokens"]) ?? CodexJSONAccess.intValue(usage["cached_input_tokens"])
		let output = CodexJSONAccess.intValue(usage["outputTokens"]) ?? CodexJSONAccess.intValue(usage["output_tokens"])
		let reasoningOutput =
			CodexJSONAccess.intValue(usage["reasoningOutputTokens"])
			?? CodexJSONAccess.intValue(usage["reasoning_output_tokens"])

		if input == nil && cachedInput == nil && output == nil && reasoningOutput == nil {
			return nil
		}
		return (input ?? 0) + (cachedInput ?? 0) + (output ?? 0) + (reasoningOutput ?? 0)
	}

	// MARK: - Turn status

	public static func mapTurnStatus(_ raw: String) -> CodexTurnStatus {
		switch raw.lowercased() {
		case "completed":
			return .completed
		case "interrupted":
			return .interrupted
		case "failed":
			return .failed
		default:
			return .completed
		}
	}

	public static func isThreadSnapshotTurnActive(_ rawStatus: String?) -> Bool {
		guard let normalized = rawStatus?
			.trimmingCharacters(in: .whitespacesAndNewlines)
			.lowercased()
		else {
			return false
		}
		return normalized == "inprogress" || normalized == "in_progress"
	}

	public static func parseTerminalTurnStatus(from rawStatus: String?) -> CodexTurnStatus? {
		guard let normalized = rawStatus?
			.trimmingCharacters(in: .whitespacesAndNewlines)
			.lowercased()
		else {
			return nil
		}
		switch normalized {
		case "completed":
			return .completed
		case "interrupted":
			return .interrupted
		case "failed":
			return .failed
		default:
			return nil
		}
	}

	// MARK: - Thread snapshot / goal projection

	public static func parseThreadSnapshot(
		from result: [String: Any],
		fallbackEffort: String?
	) -> CodexThreadSnapshot {
		let thread = result["thread"] as? [String: Any] ?? [:]
		let conversationID = CodexJSONAccess.firstString(in: thread, keys: ["id", "threadId", "thread_id", "threadID"]) ?? ""
		let rolloutPath = CodexJSONAccess.firstString(in: thread, keys: ["path"])
		let model = result["model"] as? String
		let reasoningEffort = result["reasoningEffort"] as? String ?? fallbackEffort
		let runtimeStatus = parseThreadRuntimeStatus(from: thread["status"])
		let turns = thread["turns"] as? [[String: Any]] ?? []
		var activeTurnIDs: [String] = []
		var latestTurnStatus: CodexTurnStatus?
		for turn in turns {
			let statusRaw = CodexJSONAccess.firstString(in: turn, keys: ["status"])
			if isThreadSnapshotTurnActive(statusRaw) {
				if let turnID = CodexJSONAccess.firstString(in: turn, keys: ["id", "turnId", "turn_id", "turnID"]),
					!activeTurnIDs.contains(turnID) {
					activeTurnIDs.append(turnID)
				}
			}
			if let parsedStatus = parseTerminalTurnStatus(from: statusRaw) {
				latestTurnStatus = parsedStatus
			}
		}
		return CodexThreadSnapshot(
			conversationID: conversationID,
			rolloutPath: rolloutPath,
			model: model,
			reasoningEffort: reasoningEffort,
			runtimeStatus: runtimeStatus,
			currentTurnID: activeTurnIDs.last,
			activeTurnIDs: activeTurnIDs,
			latestTurnStatus: latestTurnStatus
		)
	}

	public static func parseThreadRuntimeStatus(from raw: Any?) -> CodexThreadSnapshot.RuntimeStatus {
		if let rawStatus = raw as? [String: Any] {
			let type = CodexJSONAccess.firstString(in: rawStatus, keys: ["type"])?.lowercased()
			switch type {
			case "active":
				let activeFlags = ((rawStatus["activeFlags"] ?? rawStatus["active_flags"]) as? [Any] ?? [])
					.compactMap { CodexJSONAccess.stringScalarValue(from: $0) }
				return .active(activeFlags: activeFlags)
			case "idle":
				return .idle
			case "systemerror", "system_error":
				return .systemError
			case "notloaded", "not_loaded":
				return .notLoaded
			default:
				break
			}
		}

		let normalized = CodexJSONAccess.stringScalarValue(from: raw)?
			.trimmingCharacters(in: .whitespacesAndNewlines)
			.lowercased()
		switch normalized {
		case "active":
			return .active(activeFlags: [])
		case "idle":
			return .idle
		case "systemerror", "system_error":
			return .systemError
		case "notloaded", "not_loaded":
			return .notLoaded
		default:
			return .notLoaded
		}
	}

	public static func parseThreadGoalResponse(from result: [String: Any]) throws -> CodexThreadGoal {
		guard let rawGoal = result["goal"] else {
			throw CodexThreadGoalParseError.invalidResponse
		}
		return try parseThreadGoal(from: rawGoal)
	}

	public static func parseThreadGoal(from raw: Any?) throws -> CodexThreadGoal {
		guard let goal = raw as? [String: Any] else {
			throw CodexThreadGoalParseError.invalidResponse
		}
		let threadID = CodexJSONAccess.stringScalarValue(from: goal["threadId"])
			?? CodexJSONAccess.stringScalarValue(from: goal["thread_id"])
			?? CodexJSONAccess.stringScalarValue(from: goal["threadID"])
			?? CodexJSONAccess.stringScalarValue(from: goal["id"])
		let objective = CodexJSONAccess.stringScalarValue(from: goal["objective"])
		guard let threadID, let objective else {
			throw CodexThreadGoalParseError.invalidResponse
		}
		return CodexThreadGoal(
			threadID: threadID,
			objective: objective,
			status: try parseThreadGoalStatus(goal["status"]),
			tokenBudget: CodexJSONAccess.int64Value(goal["tokenBudget"]) ?? CodexJSONAccess.int64Value(goal["token_budget"]),
			tokensUsed: CodexJSONAccess.int64Value(goal["tokensUsed"]) ?? CodexJSONAccess.int64Value(goal["tokens_used"]) ?? 0,
			timeUsedSeconds: CodexJSONAccess.int64Value(goal["timeUsedSeconds"]) ?? CodexJSONAccess.int64Value(goal["time_used_seconds"]) ?? 0,
			createdAt: CodexJSONAccess.int64Value(goal["createdAt"]) ?? CodexJSONAccess.int64Value(goal["created_at"]) ?? 0,
			updatedAt: CodexJSONAccess.int64Value(goal["updatedAt"]) ?? CodexJSONAccess.int64Value(goal["updated_at"]) ?? 0
		)
	}

	public static func parseThreadGoalStatus(_ raw: Any?) throws -> CodexThreadGoalStatus {
		guard let normalized = CodexJSONAccess.stringScalarValue(from: raw)?
			.trimmingCharacters(in: .whitespacesAndNewlines)
			.lowercased()
			.replacingOccurrences(of: "_", with: "")
			.replacingOccurrences(of: "-", with: "")
		else {
			throw CodexThreadGoalParseError.invalidResponse
		}
		switch normalized {
		case "active":
			return .active
		case "paused":
			return .paused
		case "budgetlimited":
			return .budgetLimited
		case "complete", "completed":
			return .complete
		default:
			throw CodexThreadGoalParseError.invalidResponse
		}
	}
}
