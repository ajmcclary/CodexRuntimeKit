import Foundation

// The Codex tool-event parsing surface, moved from the controller's
// ToolEvents extension (2026-07-17, parser tranche): tool lifecycle,
// normalized/raw command execution, file-change/apply_patch streaming,
// exec-command begin/delta/end, candidate traversal, tool-name
// normalization (via the injected CodexToolNamePolicy), argument/result
// extraction, and correlation IDs. Bodies unchanged apart from
// CodexJSONAccess/CodexNotificationInterpreter qualification, the policy
// port, and debug logging riding the injected debugLog closure.

extension CodexToolEventNormalizer {
	public enum ToolLifecycleEvent {
		case call(name: String, invocationID: UUID?, argsJSON: String?, dedupKey: String)
		case result(name: String, invocationID: UUID?, argsJSON: String?, resultJSON: String, isError: Bool?, dedupKey: String)
	}

	public struct ExecCommandBeginEvent {
		public let invocationID: UUID?
		public let argsJSON: String?
		public let processID: String?
		public let dedupKey: String
	}

	public struct ExecCommandEndEvent {
		public let invocationID: UUID?
		public let argsJSON: String?
		public let resultJSON: String
		public let isError: Bool?
		public let processID: String?
		public let dedupKey: String
	}

	public func parseToolLifecycleEvent(method: String, params: [String: Any]) -> ToolLifecycleEvent? {
		let lowerMethod = method.lowercased()
		let isStarted = Self.isItemLifecycleStartedMethod(lowerMethod)
		let isCompleted = Self.isItemLifecycleCompletedMethod(lowerMethod)
		guard isStarted || isCompleted else { return nil }

		if let fileChangeEvent = parseFileChangeLifecycleEvent(method: method, params: params) {
			return fileChangeEvent
		}
		if hasNormalizedCommandExecutionCandidate(in: params) {
			return parseNormalizedCommandExecutionLifecycleEvent(method: method, params: params)
		}

		for candidate in toolItemCandidates(from: params) {
			guard isLikelyToolItem(candidate) else { continue }
			guard let toolName = normalizedToolName(from: candidate) else { continue }
			let typeRaw = normalizedTypeString(from: candidate)
			guard !Self.usesRawCanonicalLiveEventFamily(typeRaw: typeRaw) else { continue }
			let itemID = stringValue(from: candidate, keys: [
				"id", "itemId", "item_id", "callId", "call_id", "invocationId", "invocation_id", "toolCallId", "tool_call_id"
			])
			let invocationID = invocationID(from: itemID)
			let argsJSON = toolArgsJSON(from: candidate)

			if isStarted {
				let dedupKey = toolDedupKey(
					itemID: itemID,
					toolName: toolName,
					argsJSON: argsJSON,
					resultJSON: nil
				)
				return .call(name: toolName, invocationID: invocationID, argsJSON: argsJSON, dedupKey: dedupKey)
			}

			let resultJSON = toolResultJSON(from: candidate)
			let isError = toolIsError(from: candidate)
			let isCommandLike = toolName == "bash"
				|| typeRaw.contains("command")
				|| typeRaw.contains("exec")
				|| typeRaw.contains("shell")
			let completedResultJSON: String = {
				if isCommandLike {
					let commandResultJSON = jsonString(from: candidate) ?? (resultJSON ?? "")
					if isCompleted,
						Self.shouldSynthesizeTerminalCommandCompletionPayload(commandResultJSON) {
						return Self.minimalCompletedCommandExecutionResultJSON
					}
					if isCompleted,
						let object = CodexJSONAccess.object(from: commandResultJSON),
						let statusWord = Self.commandExecutionStatusWord(from: object),
						Self.commandExecutionTerminalStatusWords.contains(statusWord) {
						return Self.withCommandExecutionTerminalCompletionStatus(
							raw: commandResultJSON,
							status: statusWord
						)
					}
					if isCompleted,
						!Self.commandExecutionResultIndicatesTerminal(raw: commandResultJSON) {
						return Self.withCommandExecutionCompletedStatus(raw: commandResultJSON)
					}
					return commandResultJSON
				}
				if let resultJSON, !resultJSON.isEmpty {
					return resultJSON
				}
				if typeRaw.contains("result") || typeRaw.contains("output") || (isError == true) {
					return jsonString(from: candidate) ?? ""
				}
				return jsonString(from: candidate) ?? "{}"
			}()
			let normalizedResultJSON = isCommandLike
				? Self.sanitizedCommandExecutionResultJSON(completedResultJSON)
				: completedResultJSON
			let dedupKey = toolDedupKey(
				itemID: itemID,
				toolName: toolName,
				argsJSON: argsJSON,
				resultJSON: normalizedResultJSON
			)
			return .result(
				name: toolName,
				invocationID: invocationID,
				argsJSON: argsJSON,
				resultJSON: normalizedResultJSON,
				isError: isError,
				dedupKey: dedupKey
			)
		}
		return nil
	}

	public func parseFileChangeOutputDeltaEvent(params: [String: Any]) -> ToolLifecycleEvent? {
		let message = (params["msg"] as? [String: Any]) ?? params
		guard let itemID = stringValue(from: message, keys: ["itemId", "item_id", "id"]),
			!itemID.isEmpty else {
			return nil
		}
		// Suppress late output deltas for items that have already reached terminal state.
		guard !isFileChangeTerminal(itemID) else {
			return nil
		}
		let invocationID = invocationID(from: itemID)
		let rawOutput = rawStringValue(from: message, keys: ["delta", "output", "text", "message", "content"])
		let sanitizedOutput: String? = rawOutput.map { output in
			let sanitized = Self.sanitizeCommandOutput(output)
			if sanitized.isEmpty,
				!output.isEmpty,
				output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
				return output
			}
			return sanitized
		}

		var state = fileChangeState(for: itemID) ?? CodexToolEventNormalizer.FileChangeStreamState(
			itemID: itemID,
			invocationID: invocationID,
			argsJSON: nil,
			latestResultJSON: nil,
			accumulatedOutput: "",
			status: "running"
		)
		if let sanitizedOutput {
			state.accumulatedOutput = Self.cappedRunningOutput(state.accumulatedOutput + sanitizedOutput)
		}
		state.status = "running"
		let resultJSON = applyPatchRunningResultJSON(
			from: state.latestResultJSON,
			accumulatedOutput: state.accumulatedOutput,
			status: state.status
		)
		state.latestResultJSON = resultJSON
		updateFileChangeState(state)
		let dedupKey = toolDedupKey(
			itemID: itemID,
			toolName: "apply_patch",
			argsJSON: state.argsJSON,
			resultJSON: resultJSON
		)
		return .result(
			name: "apply_patch",
			invocationID: state.invocationID,
			argsJSON: state.argsJSON,
			resultJSON: resultJSON,
			isError: false,
			dedupKey: dedupKey
		)
	}

	public func parseRawMCPToolLifecycleEvent(
		method: String,
		params: [String: Any]
	) -> ToolLifecycleEvent? {
		let lowerMethod = method.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
		guard lowerMethod == "codex/event/mcp_tool_call_begin" || lowerMethod == "codex/event/mcp_tool_call_end" else {
			return nil
		}
		let message = (params["msg"] as? [String: Any]) ?? params
		guard let callID = stringValue(from: message, keys: ["call_id", "callId", "id"]), !callID.isEmpty else {
			return nil
		}
		let invocation = message["invocation"] as? [String: Any] ?? [:]
		var candidate = invocation
		candidate["id"] = callID
		candidate["type"] = "mcpToolCall"
		if let tool = stringValue(from: invocation, keys: ["tool"]), !tool.isEmpty {
			candidate["name"] = tool
		}
		if let server = stringValue(from: invocation, keys: ["server"]), !server.isEmpty {
			candidate["serverName"] = server
		}
		guard let toolName = normalizedToolName(from: candidate) else { return nil }
		let invocationID = invocationID(from: callID)
		let argsJSON = toolArgsJSON(from: candidate)
		if lowerMethod.hasSuffix("_begin") {
			let dedupKey = toolDedupKey(
				itemID: callID,
				toolName: toolName,
				argsJSON: argsJSON,
				resultJSON: nil
			)
			return .call(name: toolName, invocationID: invocationID, argsJSON: argsJSON, dedupKey: dedupKey)
		}
		let resultJSON = jsonString(from: message["result"] ?? [:])
			?? "{}"
		let isError = Self.mcpToolResultIsError(message["result"])
		let dedupKey = toolDedupKey(
			itemID: callID,
			toolName: toolName,
			argsJSON: argsJSON,
			resultJSON: resultJSON
		)
		return .result(
			name: toolName,
			invocationID: invocationID,
			argsJSON: argsJSON,
			resultJSON: resultJSON,
			isError: isError,
			dedupKey: dedupKey
		)
	}

	public func parseExecCommandBeginEvent(params: [String: Any]) -> ExecCommandBeginEvent? {
		let message = (params["msg"] as? [String: Any]) ?? params
		guard let callID = stringValue(from: message, keys: ["call_id", "callId", "itemId", "item_id", "id"]),
			!callID.isEmpty else {
			return nil
		}
		return ExecCommandBeginEvent(
			invocationID: invocationID(from: callID),
			argsJSON: execCommandArgsJSON(from: message),
			processID: stringValue(from: message, keys: ["process_id", "processId"]),
			dedupKey: callID
		)
	}

	public func parseExecCommandOutputDeltaUpdate(params: [String: Any]) -> CodexCommandExecutionRunningUpdate? {
		let message = (params["msg"] as? [String: Any]) ?? params
		guard let callID = stringValue(from: message, keys: ["call_id", "callId", "itemId", "item_id", "id"]),
			!callID.isEmpty else {
			return nil
		}
		let chunk = stringValue(from: message, keys: ["chunk"])
		let output = decodeExecCommandOutputChunk(chunk)
			?? stringValue(from: message, keys: ["delta", "output", "text", "message", "content"])
		let sanitizedOutput = output.map(Self.sanitizeCommandOutput)
		let trimmedOutput = sanitizedOutput?.trimmingCharacters(in: .whitespacesAndNewlines)
		return CodexCommandExecutionRunningUpdate(
			invocationID: invocationID(from: callID),
			processID: stringValue(from: message, keys: ["process_id", "processId"]),
			appendedOutput: (trimmedOutput?.isEmpty == false) ? sanitizedOutput : nil
		)
	}

	public func parseExecCommandEndEvent(params: [String: Any]) -> ExecCommandEndEvent? {
		let message = (params["msg"] as? [String: Any]) ?? params
		guard let callID = stringValue(from: message, keys: ["call_id", "callId", "itemId", "item_id", "id"]),
			!callID.isEmpty else {
			return nil
		}

		let processID = stringValue(from: message, keys: ["process_id", "processId"])
		let exitCode = CodexJSONAccess.intValue(message["exit_code"]) ?? CodexJSONAccess.intValue(message["exitCode"]) ?? CodexJSONAccess.intValue(message["code"])
		let explicitStatus = stringValue(from: message, keys: ["status"])?.lowercased()
		let status: String = {
			if let explicitStatus, !explicitStatus.isEmpty {
				return explicitStatus
			}
			if let exitCode {
				return exitCode == 0 ? "completed" : "failed"
			}
			return "finished"
		}()

		var payload: [String: Any] = [
			"type": "commandExecution",
			"status": status,
			"id": callID
		]
		if let processID, !processID.isEmpty {
			payload["processId"] = processID
		}
		if let exitCode, exitCode >= 0 {
			payload["exitCode"] = exitCode
		}
		let durationMs: Int? = {
			if let duration = message["duration"] as? [String: Any] {
				let secs = CodexJSONAccess.intValue(duration["secs"]) ?? 0
				let nanos = CodexJSONAccess.intValue(duration["nanos"]) ?? 0
				let computed = max(0, secs) * 1000 + max(0, nanos) / 1_000_000
				return computed > 0 ? computed : nil
			}
			if let explicit = CodexJSONAccess.intValue(message["duration_ms"]) ?? CodexJSONAccess.intValue(message["durationMs"]),
				explicit > 0 {
				return explicit
			}
			return nil
		}()
		if let durationMs {
			payload["durationMs"] = durationMs
		}
		if let output = stringValue(from: message, keys: [
			"aggregated_output", "aggregatedOutput",
			"formatted_output", "formattedOutput",
			"output", "stdout", "stderr",
			"text", "message"
		]),
			!output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
			payload["aggregatedOutput"] = Self.sanitizeCommandOutput(output)
		}

		let resultJSON = jsonString(from: payload) ?? Self.minimalCompletedCommandExecutionResultJSON
		let isError = Self.commandExecutionEndIsError(exitCode: exitCode, status: status)

		let argsJSON = execCommandArgsJSON(from: message)
		return ExecCommandEndEvent(
			invocationID: invocationID(from: callID),
			argsJSON: argsJSON,
			resultJSON: resultJSON,
			isError: isError,
			processID: processID,
			dedupKey: callID
		)
	}

	public func parseCommandExecutionRunningUpdateFromNotification(
		params: [String: Any],
		outputKeys: [String]
	) -> CodexCommandExecutionRunningUpdate? {
		let candidates = toolItemCandidates(from: params)
		var resolvedInvocationID: UUID?
		var resolvedProcessID: String?
		var resolvedOutput: String?
		var sealsAssistantBoundary = false

		for candidate in candidates {
			if resolvedInvocationID == nil {
				let itemID = stringValue(from: candidate, keys: [
					"itemId", "item_id", "callId", "call_id", "id", "invocationId", "invocation_id"
				])
				resolvedInvocationID = invocationID(from: itemID)
			}
			if resolvedProcessID == nil {
				resolvedProcessID = stringValue(from: candidate, keys: [
					"processId", "process_id"
				])
			}
			if resolvedOutput == nil {
				for key in outputKeys {
					if let output = stringValue(from: candidate, keys: [key]) {
						let sanitized = Self.sanitizeCommandOutput(output)
						let trimmed = sanitized.trimmingCharacters(in: .whitespacesAndNewlines)
						if !trimmed.isEmpty {
							resolvedOutput = sanitized
							break
						}
					}
				}
			}
			if let stdin = rawStringValue(from: candidate, keys: ["stdin"]), stdin.isEmpty {
				sealsAssistantBoundary = true
			}
		}

		guard resolvedInvocationID != nil || (resolvedProcessID?.isEmpty == false) else {
			return nil
		}
		return CodexCommandExecutionRunningUpdate(
			invocationID: resolvedInvocationID,
			processID: resolvedProcessID,
			appendedOutput: resolvedOutput,
			sealsAssistantBoundary: sealsAssistantBoundary
		)
	}

	public func commandExecutionItemID(from params: [String: Any]) -> String? {
		for candidate in toolItemCandidates(from: params) {
			if let itemID = stringValue(from: candidate, keys: [
				"itemId", "item_id", "callId", "call_id", "id", "invocationId", "invocation_id"
			]), !itemID.isEmpty {
				return itemID
			}
		}
		return nil
	}

	public func invocationID(from rawItemID: String?) -> UUID? {
		guard let raw = rawItemID?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
			return nil
		}
		if let parsed = UUID(uuidString: raw) {
			return parsed
		}

		// Codex sometimes emits non-UUID tool item IDs (for example "call_...").
		// Build a deterministic UUID so started/completed lifecycle events can still pair.
		var hashA: UInt64 = 0xcbf29ce484222325
		var hashB: UInt64 = 0x9e3779b97f4a7c15
		for (index, byte) in raw.utf8.enumerated() {
			hashA ^= UInt64(byte)
			hashA &*= 0x100000001b3
			hashB ^= UInt64(byte) &+ UInt64(index & 0xff)
			hashB &*= 0x100000001b3
			hashB = (hashB << 13) | (hashB >> 51)
		}

		var bytes: [UInt8] = []
		bytes.reserveCapacity(16)
		bytes.append(contentsOf: withUnsafeBytes(of: hashA.bigEndian) { Array($0) })
		bytes.append(contentsOf: withUnsafeBytes(of: hashB.bigEndian) { Array($0) })
		guard bytes.count == 16 else { return nil }

		// RFC 4122 variant + version 5-like marker for synthetic deterministic UUIDs.
		bytes[6] = (bytes[6] & 0x0f) | 0x50
		bytes[8] = (bytes[8] & 0x3f) | 0x80

		return UUID(uuid: (
			bytes[0], bytes[1], bytes[2], bytes[3],
			bytes[4], bytes[5], bytes[6], bytes[7],
			bytes[8], bytes[9], bytes[10], bytes[11],
			bytes[12], bytes[13], bytes[14], bytes[15]
		))
	}

	public func toolItemCandidates(from params: [String: Any]) -> [[String: Any]] {
		CodexNotificationInterpreter.toolItemCandidates(fromParams: params)
	}

	public func normalizedToolName(from candidate: [String: Any]) -> String? {
		let explicitName = stringValue(from: candidate, keys: [
			"name", "toolName", "tool_name", "functionName", "function_name", "callName", "call_name"
		])
		let typeRaw = normalizedTypeString(from: candidate)
		let raw = (explicitName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
		let lowered = raw.lowercased()

		if lowered == "local_shell"
			|| lowered == "shell"
			|| lowered == "unified_exec"
			|| lowered == "exec_command"
			|| lowered == "run_shell_command" {
			return "bash"
		}
		if lowered == "web_search"
			|| lowered == "web_search_request"
			|| lowered == "google_web_search"
			|| lowered == "search_web" {
			return "search"
		}
		if !raw.isEmpty {
			if isPolicyServerToolCandidate(candidate, toolName: raw) {
				let normalized = toolNamePolicy.normalizeToolName(raw)
				return "mcp__\(toolNamePolicy.mcpServerName)__\(normalized)"
			}
			return raw
		}

		if typeRaw.contains("shell") || typeRaw.contains("exec") || typeRaw.contains("command") {
			return "bash"
		}
		if typeRaw.contains("filechange") || typeRaw.contains("file_change") {
			return "apply_patch"
		}
		if typeRaw.contains("search") {
			return "search"
		}
		return nil
	}

	public func toolArgsJSON(from candidate: [String: Any]) -> String? {
		for key in ["arguments", "args", "input", "parameters", "params"] {
			if let value = candidate[key], let json = jsonString(from: value), !json.isEmpty {
				return json
			}
		}
		if let command = stringValue(from: candidate, keys: ["command", "cmd"]), !command.isEmpty {
			var payload: [String: Any] = ["command": command]
			if let processID = stringValue(from: candidate, keys: ["processId", "process_id"]),
				!processID.isEmpty {
				payload["processId"] = processID
			}
			if let cwd = stringValue(from: candidate, keys: ["cwd"]), !cwd.isEmpty {
				payload["cwd"] = cwd
			}
			return jsonString(from: payload)
		}
		if let query = stringValue(from: candidate, keys: ["query", "q", "searchQuery", "search_query"]), !query.isEmpty {
			return jsonString(from: ["query": query])
		}
		return nil
	}

	public func toolResultJSON(from candidate: [String: Any]) -> String? {
		for key in ["result", "output", "response", "content"] {
			if let value = candidate[key], let json = jsonString(from: value), !json.isEmpty {
				return json
			}
		}
		if let text = stringValue(from: candidate, keys: ["text", "message"]), !text.isEmpty {
			return text
		}
		if let error = candidate["error"], let json = jsonString(from: error), !json.isEmpty {
			return json
		}
		return nil
	}

	public func toolIsError(from candidate: [String: Any]) -> Bool? {
		let typeRaw = normalizedTypeString(from: candidate)
		let debugToolName = normalizedToolName(from: candidate) ?? "unknown"
		let debugStatus = stringValue(from: candidate, keys: ["status"])?.lowercased() ?? "nil"
		let exitCode =
			CodexJSONAccess.intValue(candidate["exitCode"])
			?? CodexJSONAccess.intValue(candidate["exit_code"])
			?? CodexJSONAccess.intValue(candidate["code"])

		// Command wrappers can report -1 even when output is usable. Treat this as unknown.
		if let exitCode, exitCode < 0, typeRaw.contains("command") {
			debugLog("[CodexNativeController] toolIsError tool=\(debugToolName) decision=nil reason=negative-exit-code-command-wrapper exitCode=\(exitCode) status=\(debugStatus)")
			return nil
		}
		if let exitCode {
			if exitCode == 0 {
				debugLog("[CodexNativeController] toolIsError tool=\(debugToolName) decision=false reason=exitCode-zero status=\(debugStatus)")
				return false
			}
			if exitCode > 0 {
				debugLog("[CodexNativeController] toolIsError tool=\(debugToolName) decision=true reason=positive-exit-code exitCode=\(exitCode) status=\(debugStatus)")
				return true
			}
		}

		if let isError = boolValue(from: candidate, keys: ["isError", "is_error"]) {
			debugLog("[CodexNativeController] toolIsError tool=\(debugToolName) decision=\(isError) reason=explicit-isError status=\(debugStatus)")
			return isError
		}
		if let status = stringValue(from: candidate, keys: ["status"])?.lowercased() {
			if status == "error" || status == "failed" || status == "failure" {
				debugLog("[CodexNativeController] toolIsError tool=\(debugToolName) decision=true reason=status-failed status=\(status)")
				return true
			}
			if status == "ok" || status == "success" || status == "completed" {
				debugLog("[CodexNativeController] toolIsError tool=\(debugToolName) decision=false reason=status-success status=\(status)")
				return false
			}
		}
		if typeRaw.contains("command") || debugToolName == "bash" || debugToolName == "exec_command" {
			debugLog("[CodexNativeController] toolIsError tool=\(debugToolName) decision=nil reason=insufficient-signals status=\(debugStatus)")
		}
		return nil
	}

	public func stringValue(from candidate: [String: Any], keys: [String]) -> String? {
		for key in keys {
			if let value = candidate[key] as? String, !value.isEmpty {
				return value
			}
		}
		return nil
	}

	public func boolValue(from candidate: [String: Any], keys: [String]) -> Bool? {
		for key in keys {
			if let value = candidate[key] as? Bool {
				return value
			}
		}
		return nil
	}

	private func hasNormalizedCommandExecutionCandidate(in params: [String: Any]) -> Bool {
		toolItemCandidates(from: params).contains { candidate in
			let typeRaw = normalizedTypeString(from: candidate)
			return typeRaw.contains("commandexecution") || typeRaw.contains("command_execution")
		}
	}

	private func parseNormalizedCommandExecutionLifecycleEvent(
		method: String,
		params: [String: Any]
	) -> ToolLifecycleEvent? {
		let lowerMethod = method.lowercased()
		let isStarted = Self.isItemLifecycleStartedMethod(lowerMethod)
		let isCompleted = Self.isItemLifecycleCompletedMethod(lowerMethod)
		guard isStarted || isCompleted else { return nil }

		for candidate in toolItemCandidates(from: params) {
			let typeRaw = normalizedTypeString(from: candidate)
			guard typeRaw.contains("commandexecution") || typeRaw.contains("command_execution") else {
				continue
			}
			let itemID = stringValue(from: candidate, keys: [
				"id", "itemId", "item_id", "callId", "call_id", "invocationId", "invocation_id"
			])
			guard shouldAcceptCommandExecutionEvent(itemID: itemID, family: .normalized) else {
				return nil
			}
			let invocationID = invocationID(from: itemID)
			let argsJSON = normalizedCommandExecutionArgsJSON(from: candidate)
			let baseDedupKey = itemID ?? toolDedupKey(
				itemID: nil,
				toolName: "bash",
				argsJSON: argsJSON,
				resultJSON: nil
			)

			if isStarted {
				return .call(
					name: "bash",
					invocationID: invocationID,
					argsJSON: argsJSON,
					dedupKey: baseDedupKey
				)
			}

			let resultJSON = normalizedCommandExecutionResultJSON(from: candidate)
			let object = CodexJSONAccess.object(from: resultJSON) ?? [:]
			let exitCode = Self.commandExecutionExitCode(from: object)
			let status = Self.commandExecutionStatusWord(from: object)
			let isError = Self.commandExecutionEndIsError(exitCode: exitCode, status: status)
			let dedupKey = itemID ?? toolDedupKey(
				itemID: nil,
				toolName: "bash",
				argsJSON: argsJSON,
				resultJSON: resultJSON
			)
			return .result(
				name: "bash",
				invocationID: invocationID,
				argsJSON: argsJSON,
				resultJSON: resultJSON,
				isError: isError,
				dedupKey: dedupKey
			)
		}
		return nil
	}

	private func normalizedCommandExecutionArgsJSON(from candidate: [String: Any]) -> String? {
		var args: [String: Any] = [:]
		if let command = stringValue(from: candidate, keys: ["command", "cmd"]), !command.isEmpty {
			args["command"] = command
		}
		if let cwd = stringValue(from: candidate, keys: ["cwd"]), !cwd.isEmpty {
			args["cwd"] = cwd
		}
		if let processID = stringValue(from: candidate, keys: ["processId", "process_id"]), !processID.isEmpty {
			args["processId"] = processID
		}
		let commandActions = candidate["commandActions"] ?? candidate["command_actions"]
		if let commandActions, JSONSerialization.isValidJSONObject(["commandActions": commandActions]) {
			args["commandActions"] = commandActions
		}
		return args.isEmpty ? nil : jsonString(from: args)
	}

	private func normalizedCommandExecutionResultJSON(from candidate: [String: Any]) -> String {
		let rawStatus = stringValue(from: candidate, keys: ["status"])
		let exitCode = CodexJSONAccess.intValue(candidate["exitCode"]) ?? CodexJSONAccess.intValue(candidate["exit_code"]) ?? CodexJSONAccess.intValue(candidate["code"])
		let status: String = {
			if let mapped = Self.normalizedCommandExecutionStatusWord(rawStatus) {
				return mapped
			}
			if let exitCode {
				return exitCode == 0 ? "completed" : "failed"
			}
			return "completed"
		}()

		var payload: [String: Any] = [
			"type": "commandExecution",
			"status": status
		]
		if let itemID = stringValue(from: candidate, keys: ["id", "itemId", "item_id"]), !itemID.isEmpty {
			payload["id"] = itemID
		}
		if let command = stringValue(from: candidate, keys: ["command", "cmd"]), !command.isEmpty {
			payload["command"] = command
		}
		if let cwd = stringValue(from: candidate, keys: ["cwd"]), !cwd.isEmpty {
			payload["cwd"] = cwd
		}
		if let processID = stringValue(from: candidate, keys: ["processId", "process_id"]), !processID.isEmpty {
			payload["processId"] = processID
		}
		if let source = stringValue(from: candidate, keys: ["source"]), !source.isEmpty {
			payload["source"] = source
		}
		if let exitCode, exitCode >= 0 {
			payload["exitCode"] = exitCode
		}
		if let durationMs = CodexJSONAccess.intValue(candidate["durationMs"]) ?? CodexJSONAccess.intValue(candidate["duration_ms"]), durationMs >= 0 {
			payload["durationMs"] = durationMs
		}
		if let output = stringValue(from: candidate, keys: Self.commandExecutionOutputKeys),
			!output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
			payload["aggregatedOutput"] = Self.sanitizeCommandOutput(output)
		}
		let commandActions = candidate["commandActions"] ?? candidate["command_actions"]
		if let commandActions, JSONSerialization.isValidJSONObject(["commandActions": commandActions]) {
			payload["commandActions"] = commandActions
		}
		return CommandExecutionPayloadHelper.encodeJSONObject(payload)
			?? Self.minimalCompletedCommandExecutionResultJSON
	}

	private func parseFileChangeLifecycleEvent(method: String, params: [String: Any]) -> ToolLifecycleEvent? {
		let lowerMethod = method.lowercased()
		let isStarted = Self.isItemLifecycleStartedMethod(lowerMethod)
		let isCompleted = Self.isItemLifecycleCompletedMethod(lowerMethod)
		guard isStarted || isCompleted else { return nil }
		guard let candidate = toolItemCandidates(from: params).first(where: { CodexNotificationInterpreter.candidateLooksLikeFileChange($0) }) else {
			return nil
		}
		let itemID = stringValue(from: candidate, keys: ["id", "itemId", "item_id"])
		guard let itemID, !itemID.isEmpty else { return nil }
		let invocationID = invocationID(from: itemID)
		let existingState = fileChangeState(for: itemID)
		let argsJSON = applyPatchArgsJSON(from: candidate) ?? existingState?.argsJSON
		let statusInfo = Self.normalizedApplyPatchStatus(
			from: stringValue(from: candidate, keys: ["status"]),
			isCompletedLifecycle: isCompleted
		)
		let resultJSON = applyPatchResultJSON(
			from: candidate,
			accumulatedOutput: existingState?.accumulatedOutput
		)

		if isStarted {
			fileChangeStreamStarted(.init(
				itemID: itemID,
				invocationID: invocationID,
				argsJSON: argsJSON,
				latestResultJSON: resultJSON,
				accumulatedOutput: existingState?.accumulatedOutput ?? "",
				status: statusInfo.status
			))
			let dedupKey = toolDedupKey(
				itemID: itemID,
				toolName: "apply_patch",
				argsJSON: argsJSON,
				resultJSON: nil
			)
			return .call(name: "apply_patch", invocationID: invocationID, argsJSON: argsJSON, dedupKey: dedupKey)
		}

		fileChangeStreamCompleted(itemID: itemID)
		let dedupKey = toolDedupKey(
			itemID: itemID,
			toolName: "apply_patch",
			argsJSON: argsJSON,
			resultJSON: resultJSON
		)
		return .result(
			name: "apply_patch",
			invocationID: invocationID,
			argsJSON: argsJSON,
			resultJSON: resultJSON,
			isError: statusInfo.isError,
			dedupKey: dedupKey
		)
	}

	private func applyPatchArgsJSON(from candidate: [String: Any]) -> String? {
		let changePayloads = applyPatchChangePayloads(from: candidate)
		var seenPaths: Set<String> = []
		let paths = changePayloads.compactMap { payload -> String? in
			guard let path = payload["path"] as? String, !path.isEmpty else { return nil }
			guard seenPaths.insert(path).inserted else { return nil }
			return path
		}
		guard !paths.isEmpty || !changePayloads.isEmpty else { return nil }
		var payload: [String: Any] = [
			"change_count": max(changePayloads.count, paths.count)
		]
		if let first = paths.first {
			payload["path"] = first
		}
		if paths.count > 1 {
			payload["paths"] = paths
		}
		return jsonString(from: payload)
	}

	private func applyPatchResultJSON(from candidate: [String: Any], accumulatedOutput: String?) -> String {
		let changePayloads = applyPatchChangePayloads(from: candidate)
		let statusInfo = Self.normalizedApplyPatchStatus(
			from: stringValue(from: candidate, keys: ["status"])
		)
		var payload: [String: Any] = [
			"status": statusInfo.status,
			"changes": changePayloads,
			"change_count": changePayloads.count,
			"summary_only": false
		]
		if let accumulatedOutput, !accumulatedOutput.isEmpty {
			payload["output"] = accumulatedOutput
		}
		return jsonString(from: payload) ?? "{\"status\":\"\(statusInfo.status)\",\"changes\":[],\"change_count\":0}"
	}

	private func applyPatchRunningResultJSON(
		from raw: String?,
		accumulatedOutput: String,
		status: String
	) -> String {
		var object = CodexJSONAccess.object(from: raw) ?? [:]
		object["status"] = status
		object["summary_only"] = false
		if object["changes"] == nil {
			object["changes"] = []
		}
		if object["change_count"] == nil {
			let changes = object["changes"] as? [Any] ?? []
			object["change_count"] = changes.count
		}
		if !accumulatedOutput.isEmpty {
			object["output"] = accumulatedOutput
		}
		return jsonString(from: object) ?? "{\"status\":\"running\",\"changes\":[],\"change_count\":0}"
	}

	private func applyPatchChangePayloads(from candidate: [String: Any]) -> [[String: Any]] {
		let rawChanges = candidate["changes"] as? [Any] ?? []
		return rawChanges.compactMap { rawChange in
			guard let change = rawChange as? [String: Any],
				let path = stringValue(from: change, keys: ["path"]),
				let diff = rawStringValue(from: change, keys: ["diff"]) else {
				return nil
			}
			let kindInfo = Self.normalizedApplyPatchKindAndMovePath(from: change["kind"])
			var payload: [String: Any] = [
				"path": path,
				"kind": kindInfo.kind,
				"diff": diff
			]
			if let movePath = kindInfo.movePath, !movePath.isEmpty {
				payload["move_path"] = movePath
			}
			return payload
		}
	}

	private func execCommandArgsJSON(from message: [String: Any]) -> String? {
		var args: [String: Any] = [:]
		if let command = message["command"] as? [Any] {
			let argv = command
				.compactMap { $0 as? String }
				.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
				.filter { !$0.isEmpty }
			if !argv.isEmpty {
				args["argv"] = argv
			}
		}
		if args["argv"] == nil,
			let command = stringValue(from: message, keys: ["command", "cmd"]),
			!command.isEmpty {
			args["command"] = command
		}
		if let cwd = stringValue(from: message, keys: ["cwd"]), !cwd.isEmpty {
			args["cwd"] = cwd
		}
		if let processID = stringValue(from: message, keys: ["process_id", "processId"]), !processID.isEmpty {
			args["processId"] = processID
		}
		if args.isEmpty,
			let invocation = message["invocation"] as? [String: Any] {
			if let arguments = invocation["arguments"] {
				return jsonString(from: arguments)
			}
			if let command = invocation["command"] as? [Any] {
				let argv = command
					.compactMap { $0 as? String }
					.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
					.filter { !$0.isEmpty }
				if !argv.isEmpty {
					args["argv"] = argv
				}
			}
			if let command = stringValue(from: invocation, keys: ["command", "cmd"]), !command.isEmpty {
				args["command"] = command
			}
			if let cwd = stringValue(from: invocation, keys: ["cwd"]), !cwd.isEmpty {
				args["cwd"] = cwd
			}
		}
		guard !args.isEmpty else { return nil }
		return jsonString(from: args)
	}

	private func decodeExecCommandOutputChunk(_ chunk: String?) -> String? {
		guard let chunk, !chunk.isEmpty else { return nil }
		guard let data = Data(base64Encoded: chunk),
			let decoded = String(data: data, encoding: .utf8),
			!decoded.isEmpty else {
			return chunk
		}
		return decoded
	}

	private func normalizedTypeString(from candidate: [String: Any]) -> String {
		let raw = stringValue(from: candidate, keys: ["type", "itemType", "item_type"]) ?? ""
		return raw
			.trimmingCharacters(in: .whitespacesAndNewlines)
			.lowercased()
	}

	private func isLikelyToolItem(_ candidate: [String: Any]) -> Bool {
		let typeRaw = normalizedTypeString(from: candidate)
		let typeHints = ["tool", "function", "shell", "search", "exec", "command", "mcp"]
		if typeHints.contains(where: { typeRaw.contains($0) }) {
			return true
		}
		if let _ = stringValue(from: candidate, keys: ["name", "toolName", "tool_name", "functionName", "function_name"]) {
			return true
		}
		return false
	}

	private func isPolicyServerToolCandidate(_ candidate: [String: Any], toolName: String) -> Bool {
		let repoPromptServer = toolNamePolicy.mcpServerName.lowercased()
		let mcpPrefix = "mcp__\(repoPromptServer)__"
		if toolNamePolicy.hasExplicitServerPrefix(toolName) {
			return true
		}

		let identifyingKeys = [
			"name", "toolName", "tool_name", "functionName", "function_name", "callName", "call_name",
			"server", "serverName", "server_name", "mcpServer", "mcp_server", "mcpServerName", "mcp_server_name",
			"toolNamespace", "tool_namespace", "provider", "namespace", "origin"
		]
		for key in identifyingKeys {
			guard let value = candidate[key] as? String else { continue }
			let lowered = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
			if lowered.isEmpty { continue }
			if lowered.hasPrefix(mcpPrefix) {
				return true
			}
			if key == "server" || key == "serverName" || key == "server_name"
				|| key == "mcpServer" || key == "mcp_server" || key == "mcpServerName" || key == "mcp_server_name"
				|| key == "toolNamespace" || key == "tool_namespace" || key == "provider" || key == "namespace" || key == "origin" {
				if toolNamePolicy.matchesServerIdentifier(lowered) {
					return true
				}
			}
		}
		return false
	}

	private func rawStringValue(from candidate: [String: Any], keys: [String]) -> String? {
		for key in keys {
			if let value = candidate[key] as? String {
				return value
			}
		}
		return nil
	}

	private func jsonString(from value: Any) -> String? {
		if let value = value as? String {
			return value
		}
		if JSONSerialization.isValidJSONObject(value),
			let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted]),
			let json = String(data: data, encoding: .utf8) {
			return json
		}
		return nil
	}

	static func usesRawCanonicalLiveEventFamily(typeRaw: String) -> Bool {
		typeRaw.contains("mcptoolcall")
			|| typeRaw.contains("mcp_tool_call")
	}
}
