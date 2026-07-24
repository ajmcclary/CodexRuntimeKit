import Foundation

// Command-execution / apply_patch / write_stdin payload transforms, moved
// from the controller's CommandProjection and ToolEvents extensions
// (2026-07-17, parser tranche). Pure wire-payload -> payload/JSON logic;
// AgentChatItem projection and persisted-rollout reconciliation stay
// app-side. Bodies unchanged apart from CodexJSONAccess qualification.

extension CodexToolEventNormalizer {
	public static let maxRunningAggregatedOutputCharacters = 24_000
	public static let runningOutputTruncationMarker = "\n...(output truncated)...\n"

	public enum CommandExecutionPayloadHelper {
		public static func object(from raw: String?) -> [String: Any] {
			CodexJSONAccess.object(from: raw) ?? [:]
		}

		public static func seedAggregatedOutputIfNeeded(object: inout [String: Any], raw: String?) {
			guard object.isEmpty,
				let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
				!raw.isEmpty else { return }
			let sanitizedRaw = CodexToolEventNormalizer.sanitizeCommandOutput(raw)
			guard !sanitizedRaw.isEmpty else { return }
			object["aggregatedOutput"] = sanitizedRaw
		}

		public static func markRunning(object: inout [String: Any], processID: String?) {
			object["type"] = (CodexJSONAccess.string(object, key: "type")?.isEmpty == false)
				? object["type"]
				: "commandExecution"
			object["status"] = "running"
			object.removeValue(forKey: "exitCode")
			object.removeValue(forKey: "exit_code")
			object.removeValue(forKey: "code")

			let existingProcessID =
				CodexJSONAccess.string(object, key: "processId")
				?? CodexJSONAccess.string(object, key: "process_id")
			if let processID, !processID.isEmpty {
				object["processId"] = processID
			} else if let existingProcessID, !existingProcessID.isEmpty {
				object["processId"] = existingProcessID
			}
			object.removeValue(forKey: "process_id")
		}

		public static func mergeAggregatedOutput(object: inout [String: Any], appendOutput: String?) {
			var aggregatedOutput =
				CodexJSONAccess.string(object, key: "aggregatedOutput")
				?? CodexJSONAccess.string(object, key: "aggregated_output")
				?? outputText(from: object)
				?? ""
			// Avoid re-sanitizing the full accumulated transcript on every delta append.
			// Sanitize existing output only when it still contains control/escape markers.
			if !aggregatedOutput.isEmpty && containsControlOrEscapeMarkers(aggregatedOutput) {
				aggregatedOutput = CodexToolEventNormalizer.sanitizeCommandOutput(aggregatedOutput)
			}
			if let appendOutput, !appendOutput.isEmpty {
				let sanitizedAppend = CodexToolEventNormalizer.sanitizeCommandOutput(appendOutput)
				if !sanitizedAppend.isEmpty {
					aggregatedOutput += sanitizedAppend
				}
			}
			if !aggregatedOutput.isEmpty {
				object["aggregatedOutput"] = CodexToolEventNormalizer.cappedRunningOutput(aggregatedOutput)
			}
			object.removeValue(forKey: "aggregated_output")
		}

		public static func outputText(from object: [String: Any]) -> String? {
			for key in CodexToolEventNormalizer.commandExecutionOutputKeys {
				if let value = CodexJSONAccess.string(object, key: key) {
					let sanitized = CodexToolEventNormalizer.sanitizeCommandOutput(value)
					let trimmed = sanitized.trimmingCharacters(in: .whitespacesAndNewlines)
					if !trimmed.isEmpty {
						return sanitized
					}
				}
			}
			return nil
		}

		public static func sanitizeOutputFields(in object: inout [String: Any]) -> Bool {
			var didChange = false
			for key in CodexToolEventNormalizer.commandExecutionOutputKeys {
				guard let value = CodexJSONAccess.string(object, key: key) else { continue }
				let sanitized = CodexToolEventNormalizer.sanitizeCommandOutput(value)
				guard sanitized != value else { continue }
				object[key] = sanitized
				didChange = true
			}
			return didChange
		}

		public static func encodeJSONObject(_ object: [String: Any]) -> String? {
			guard JSONSerialization.isValidJSONObject(object),
				let data = try? JSONSerialization.data(withJSONObject: object, options: []),
				let json = String(data: data, encoding: .utf8) else {
				return nil
			}
			return json
		}

		private static func containsControlOrEscapeMarkers(_ text: String) -> Bool {
			text.contains("\u{001B}")
				|| text.contains("\u{009B}")
				|| text.contains("\u{0008}")
				|| text.contains("\r")
		}
	}

	public static func withCommandExecutionRunningStatus(
		raw: String?,
		processID: String?,
		appendOutput: String?
	) -> String {
		var object = CommandExecutionPayloadHelper.object(from: raw)
		CommandExecutionPayloadHelper.seedAggregatedOutputIfNeeded(object: &object, raw: raw)
		CommandExecutionPayloadHelper.markRunning(object: &object, processID: processID)
		CommandExecutionPayloadHelper.mergeAggregatedOutput(object: &object, appendOutput: appendOutput)
		return CommandExecutionPayloadHelper.encodeJSONObject(object)
			?? (raw ?? "{\"type\":\"commandExecution\",\"status\":\"running\"}")
	}

	public static func cappedRunningOutput(_ raw: String) -> String {
		guard raw.count > maxRunningAggregatedOutputCharacters else { return raw }
		let suffix = String(raw.suffix(maxRunningAggregatedOutputCharacters))
		if suffix.hasPrefix(runningOutputTruncationMarker) {
			return suffix
		}
		return runningOutputTruncationMarker + suffix
	}

	public static func mcpToolResultIsError(_ value: Any?) -> Bool? {
		guard let result = value as? [String: Any] else { return nil }
		if result["Err"] != nil {
			return true
		}
		if let ok = result["Ok"] as? [String: Any], let isError = ok["isError"] as? Bool {
			return isError
		}
		return nil
	}

	public static func textFromMCPToolResult(_ value: Any?) -> String? {
		guard let result = value as? [String: Any],
			let ok = result["Ok"] as? [String: Any] else {
			return nil
		}
		if let content = ok["content"] as? [[String: Any]] {
			let text = content
				.compactMap { block -> String? in
					guard (block["type"] as? String) == "text" else { return nil }
					return block["text"] as? String
				}
				.joined(separator: "\n")
				.trimmingCharacters(in: .whitespacesAndNewlines)
			return text.isEmpty ? nil : text
		}
		if let text = ok["text"] as? String {
			let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
			return trimmed.isEmpty ? nil : trimmed
		}
		return nil
	}

	public static func parseExecCommandRunningOutput(raw: String) -> (processID: String, output: String?)? {
		let normalized = raw.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
		guard let processRange = normalized.range(of: #"Process running with session ID\s+([0-9]+)"#, options: .regularExpression) else {
			return nil
		}
		let processLine = String(normalized[processRange])
		let processID = processLine.components(separatedBy: CharacterSet.decimalDigits.inverted).joined()
		guard !processID.isEmpty else { return nil }

		var outputText: String?
		if let outputHeaderRange = normalized.range(of: "Output:\n") {
			let tail = String(normalized[outputHeaderRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
			if !tail.isEmpty {
				let sanitizedTail = sanitizeCommandOutput(tail)
				if !sanitizedTail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
					outputText = sanitizedTail
				}
			}
		}
		return (processID, outputText)
	}

	public static func commandExecutionOutputText(from raw: String?) -> String? {
		guard let object = CodexJSONAccess.object(from: raw) else { return nil }
		return CommandExecutionPayloadHelper.outputText(from: object)
	}

	public static func mergeCommandExecutionCompletionPayload(
		existing: String?,
		incoming: String,
		argsJSON: String?
	) -> String {
		guard var incomingObject = CodexJSONAccess.object(from: incoming) else { return incoming }
		guard commandExecutionObjectIsCommandLike(incomingObject) else { return incoming }

		let incomingCommand = CodexJSONAccess.string(incomingObject, key: "command")?
			.trimmingCharacters(in: .whitespacesAndNewlines)
		let incomingProcessID = commandExecutionProcessID(from: incoming)
		let incomingOutput = CommandExecutionPayloadHelper.outputText(from: incomingObject)?
			.trimmingCharacters(in: .whitespacesAndNewlines)

		if (incomingCommand?.isEmpty != false) || incomingProcessID == nil || (incomingOutput?.isEmpty != false) {
			let existingObject = CodexJSONAccess.object(from: existing)

			if incomingCommand?.isEmpty != false,
				let existingCommand = CodexJSONAccess.string(existingObject ?? [:], key: "command")?
					.trimmingCharacters(in: .whitespacesAndNewlines),
				!existingCommand.isEmpty {
				incomingObject["command"] = existingCommand
			} else if incomingCommand?.isEmpty != false,
				let argsObject = CodexJSONAccess.object(from: argsJSON),
				let argsCommand = commandFromCommandPayload(argsObject),
				!argsCommand.isEmpty {
				incomingObject["command"] = argsCommand
			}

			if incomingProcessID == nil,
				let existingProcessID = commandExecutionProcessID(from: existing),
				!existingProcessID.isEmpty {
				incomingObject["processId"] = existingProcessID
				incomingObject.removeValue(forKey: "process_id")
			}

			if incomingOutput?.isEmpty != false,
				let existingOutput = CommandExecutionPayloadHelper.outputText(from: existingObject ?? [:])?
					.trimmingCharacters(in: .whitespacesAndNewlines),
				!existingOutput.isEmpty {
				incomingObject["aggregatedOutput"] = cappedRunningOutput(sanitizeCommandOutput(existingOutput))
				incomingObject.removeValue(forKey: "aggregated_output")
			}
		}

		return CommandExecutionPayloadHelper.encodeJSONObject(incomingObject) ?? incoming
	}

	public static func commandFromCommandPayload(_ value: Any?) -> String? {
		if let object = value as? [String: Any] {
			for key in ["command", "cmd", "input", "text", "value", "argv", "args"] {
				if let command = commandFromCommandPayload(object[key]), !command.isEmpty {
					return command
				}
			}
			if let invocationCommand = commandFromCommandPayload(object["invocation"]), !invocationCommand.isEmpty {
				return invocationCommand
			}
			if let argumentsCommand = commandFromCommandPayload(object["arguments"]), !argumentsCommand.isEmpty {
				return argumentsCommand
			}
			return nil
		}

		if let array = value as? [Any] {
			let parts = array.compactMap { element -> String? in
				if let string = element as? String {
					let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
					return trimmed.isEmpty ? nil : trimmed
				}
				if let number = element as? NSNumber {
					let trimmed = number.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
					return trimmed.isEmpty ? nil : trimmed
				}
				return nil
			}
			if !parts.isEmpty {
				return parts.joined(separator: " ")
			}
			for nested in array {
				if let command = commandFromCommandPayload(nested), !command.isEmpty {
					return command
				}
			}
			return nil
		}

		if let string = value as? String {
			let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
			if trimmed.isEmpty { return nil }
			if (trimmed.hasPrefix("{") || trimmed.hasPrefix("[") || trimmed.hasPrefix("\"")),
				let data = trimmed.data(using: .utf8),
				let nested = try? JSONSerialization.jsonObject(with: data, options: []),
				let nestedCommand = commandFromCommandPayload(nested),
				!nestedCommand.isEmpty {
				return nestedCommand
			}
			if trimmed.count >= 2,
				let first = trimmed.first,
				let last = trimmed.last,
				first == last,
				(first == "\"" || first == "'") {
				let inner = String(trimmed.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
				if !inner.isEmpty { return inner }
			}
			return trimmed
		}

		if let number = value as? NSNumber {
			let trimmed = number.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
			return trimmed.isEmpty ? nil : trimmed
		}
		return nil
	}

	public static func sanitizedCommandExecutionResultJSON(_ raw: String) -> String {
		guard var object = CodexJSONAccess.object(from: raw) else {
			return sanitizeCommandOutput(raw)
		}
		guard CommandExecutionPayloadHelper.sanitizeOutputFields(in: &object),
			let json = CommandExecutionPayloadHelper.encodeJSONObject(object) else {
			return raw
		}
		return json
	}

	public static func sanitizeCommandOutput(_ raw: String) -> String {
		CommandExecutionOutputSanitizer.sanitize(raw)
	}

	public static let commandExecutionOutputKeys: [String] = [
		"formattedOutput",
		"formatted_output",
		"aggregatedOutput",
		"aggregated_output",
		"output",
		"stdout",
		"stderr",
		"combinedOutput",
		"combined_output",
		"recentOutput",
		"recent_output",
		"text",
		"message",
		"content",
		"result",
		"log",
		"logs"
	]

	public static let commandExecutionRunningStatusWords: Set<String> = [
		"running", "in_progress", "inprogress", "in-progress", "pending"
	]

	public static let commandExecutionTerminalStatusWords: Set<String> = [
		"completed", "complete", "success", "succeeded", "ok", "failed", "failure", "error",
		"cancelled", "canceled", "terminated", "stopped", "done", "exited", "finished",
		"timeout", "timed_out", "killed"
	]

	public static func commandExecutionResultIndicatesRunning(raw: String?) -> Bool {
		guard let object = CodexJSONAccess.object(from: raw) else { return false }
		guard commandExecutionObjectIsCommandLike(object) else { return false }

		let exitCode = commandExecutionExitCode(from: object)
		let processID = commandExecutionProcessID(from: raw)

		if let statusWord = commandExecutionStatusWord(from: object),
			commandExecutionRunningStatusWords.contains(statusWord) {
			return true
		}

		if let exitCode {
			if exitCode >= 0 {
				return false
			}
			if processID != nil {
				return true
			}
		}

		return false
	}

	public static func shouldPatchCommandExecutionRunningPayload(
		raw: String?,
		processID: String?,
		appendOutput: String?
	) -> Bool {
		if appendOutput?.isEmpty == false {
			return true
		}
		guard let object = CodexJSONAccess.object(from: raw) else {
			return true
		}
		guard commandExecutionObjectIsCommandLike(object) else {
			return true
		}
		if object["process_id"] != nil
			|| object["aggregated_output"] != nil
			|| object["exit_code"] != nil
			|| object["code"] != nil {
			return true
		}
		if commandExecutionExitCode(from: object) != nil {
			return true
		}
		let existingProcessID =
			CodexJSONAccess.string(object, key: "processId")
			?? CodexJSONAccess.string(object, key: "process_id")
		if let processID = processID?.trimmingCharacters(in: .whitespacesAndNewlines),
			!processID.isEmpty,
			processID != existingProcessID {
			return true
		}
		guard let statusWord = commandExecutionStatusWord(from: object) else {
			return true
		}
		return !commandExecutionRunningStatusWords.contains(statusWord)
	}

	public static func commandExecutionResultIndicatesTerminal(raw: String?) -> Bool {
		guard let object = CodexJSONAccess.object(from: raw) else { return false }
		let exitCode = commandExecutionExitCode(from: object)
		let processID = commandExecutionProcessID(from: raw)

		if let exitCode {
			if exitCode >= 0 {
				return true
			}
			// Some wrappers report status=failed + exitCode<0 while the underlying
			// process is still running. Keep those non-terminal when we have a PID.
			return processID == nil
		}

		if let statusWord = commandExecutionStatusWord(from: object) {
			if commandExecutionRunningStatusWords.contains(statusWord) {
				return false
			}
			if commandExecutionTerminalStatusWords.contains(statusWord) {
				return true
			}
		}
		if CodexJSONAccess.bool(object, key: "success") == true || CodexJSONAccess.bool(object, key: "ok") == true {
			return true
		}
		if let errorText = CodexJSONAccess.string(object, key: "error")?.trimmingCharacters(in: .whitespacesAndNewlines),
			!errorText.isEmpty {
			return true
		}
		return false
	}

	public static func commandExecutionObjectIsCommandLike(_ object: [String: Any]) -> Bool {
		let type = CodexJSONAccess.string(object, key: "type")?.lowercased() ?? ""
		return type.contains("command")
	}

	public static func commandExecutionExitCode(from object: [String: Any]) -> Int? {
		CodexJSONAccess.int(object, key: "exitCode")
			?? CodexJSONAccess.int(object, key: "exit_code")
			?? CodexJSONAccess.int(object, key: "code")
	}

	public static func commandExecutionStatusWord(from object: [String: Any]) -> String? {
		CodexJSONAccess.string(object, key: "status")?
			.trimmingCharacters(in: .whitespacesAndNewlines)
			.lowercased()
	}

	public static func isItemLifecycleNotificationMethod(_ method: String) -> Bool {
		let lowerMethod = method.lowercased()
		return isItemLifecycleStartedMethod(lowerMethod) || isItemLifecycleCompletedMethod(lowerMethod)
	}

	public static func isItemLifecycleStartedMethod(_ lowerMethod: String) -> Bool {
		guard lowerMethod.contains("item/") || lowerMethod.contains("item_") else { return false }
		return lowerMethod.hasSuffix("/started") || lowerMethod.hasSuffix("_started")
	}

	public static func isItemLifecycleCompletedMethod(_ lowerMethod: String) -> Bool {
		guard lowerMethod.contains("item/") || lowerMethod.contains("item_") else { return false }
		return lowerMethod.hasSuffix("/completed") || lowerMethod.hasSuffix("_completed")
	}

	public static let minimalCompletedCommandExecutionResultJSON = #"{"type":"commandExecution","status":"completed"}"#

	public static func withCommandExecutionCompletedStatus(raw: String?) -> String {
		withCommandExecutionTerminalCompletionStatus(raw: raw, status: "completed")
	}

	public static func withCommandExecutionTerminalCompletionStatus(raw: String?, status: String) -> String {
		let normalizedStatus = status
			.trimmingCharacters(in: .whitespacesAndNewlines)
			.lowercased()
		let fallbackStatus = normalizedStatus.isEmpty ? "completed" : normalizedStatus
		guard var object = CodexJSONAccess.object(from: raw) else {
			return #"{"type":"commandExecution","status":"\#(fallbackStatus)"}"#
		}
		if object.isEmpty {
			return #"{"type":"commandExecution","status":"\#(fallbackStatus)"}"#
		}
		if CodexJSONAccess.string(object, key: "type")?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
			object["type"] = "commandExecution"
		}
		object["status"] = fallbackStatus
		if object["processId"] == nil, let legacy = object["process_id"] {
			object["processId"] = legacy
		}
		object.removeValue(forKey: "process_id")

		let resolvedExitCode =
			CodexJSONAccess.int(object, key: "exitCode")
			?? CodexJSONAccess.int(object, key: "exit_code")
			?? CodexJSONAccess.int(object, key: "code")
		if let resolvedExitCode, resolvedExitCode >= 0 {
			object["exitCode"] = resolvedExitCode
		} else {
			object.removeValue(forKey: "exitCode")
		}
		object.removeValue(forKey: "exit_code")
		object.removeValue(forKey: "code")

		guard JSONSerialization.isValidJSONObject(object),
			let data = try? JSONSerialization.data(withJSONObject: object, options: []),
			let json = String(data: data, encoding: .utf8) else {
			return #"{"type":"commandExecution","status":"\#(fallbackStatus)"}"#
		}
		return json
	}

	public static func shouldSynthesizeTerminalCommandCompletionPayload(_ raw: String?) -> Bool {
		guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
			return true
		}
		guard let object = CodexJSONAccess.object(from: raw) else {
			return false
		}
		return object.isEmpty
	}

	public static let applyPatchRunningStatusWords: Set<String> = [
		"running", "pending", "in_progress", "inprogress"
	]

	public static let applyPatchTerminalStatusWords: Set<String> = [
		"success", "completed", "succeeded", "ok",
		"declined", "rejected",
		"cancelled", "canceled", "interrupted", "stopped", "terminated",
		"failed", "failure", "error"
	]

	/// Extracts the `status` field from an apply_patch result JSON string.
	public static func applyPatchStatusWord(from raw: String?) -> String? {
		guard let object = CodexJSONAccess.object(from: raw) else { return nil }
		guard let status = (object["status"] as? String)?
			.trimmingCharacters(in: .whitespacesAndNewlines)
			.lowercased(),
			!status.isEmpty else {
			return nil
		}
		return status
	}

	/// Returns `true` when the apply_patch result JSON indicates a running/in-progress state.
	public static func applyPatchResultIndicatesRunning(raw: String?) -> Bool {
		guard let status = applyPatchStatusWord(from: raw) else { return false }
		return applyPatchRunningStatusWords.contains(status)
	}

	/// Returns `true` when the apply_patch result JSON indicates a terminal (completed/failed) state.
	public static func applyPatchResultIndicatesTerminal(raw: String?) -> Bool {
		guard let status = applyPatchStatusWord(from: raw) else { return false }
		return applyPatchTerminalStatusWords.contains(status)
	}

	public static func normalizedApplyPatchKindAndMovePath(from raw: Any?) -> (kind: String, movePath: String?) {
		if let raw = raw as? String {
			return (raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), nil)
		}
		if let object = raw as? [String: Any] {
			let kind = CodexJSONAccess.string(object, key: "type")?
				.trimmingCharacters(in: .whitespacesAndNewlines)
				.lowercased() ?? "update"
			let movePath = CodexJSONAccess.string(object, key: "movePath") ?? CodexJSONAccess.string(object, key: "move_path")
			return (kind, movePath)
		}
		return ("update", nil)
	}

	public static func normalizedApplyPatchStatus(
		from rawStatus: String?,
		isCompletedLifecycle: Bool = false
	) -> (status: String, isError: Bool?) {
		let normalized = rawStatus?
			.trimmingCharacters(in: .whitespacesAndNewlines)
			.lowercased() ?? ""
		switch normalized {
		case "inprogress", "in_progress", "running", "pending":
			return isCompletedLifecycle ? ("success", false) : ("running", false)
		case "completed", "success", "succeeded", "ok":
			return ("success", false)
		case "declined", "rejected":
			return ("declined", true)
		case "cancelled", "canceled", "interrupted", "stopped", "terminated":
			return ("cancelled", true)
		case "failed", "failure", "error":
			return ("failed", true)
		default:
			if isCompletedLifecycle && normalized.isEmpty {
				return ("success", false)
			}
			return (normalized.isEmpty ? "running" : normalized, nil)
		}
	}

	public static func commandExecutionEndIsError(exitCode: Int?, status: String?) -> Bool? {
		let normalizedStatus = status?
			.trimmingCharacters(in: .whitespacesAndNewlines)
			.lowercased()
		switch normalizedStatus {
		case "failed", "error", "cancelled", "canceled":
			return true
		case "ok", "success", "succeeded", "complete", "completed":
			return false
		default:
			break
		}
		if let exitCode {
			return exitCode != 0
		}
		return nil
	}

	public static func normalizedCommandExecutionStatusWord(_ rawStatus: String?) -> String? {
		guard let rawStatus = rawStatus?
			.trimmingCharacters(in: .whitespacesAndNewlines),
			!rawStatus.isEmpty else {
			return nil
		}
		let normalized = rawStatus.lowercased()
		switch normalized {
		case "inprogress", "in_progress", "in-progress", "running", "pending":
			return "running"
		case "declined":
			return "failed"
		default:
			return normalized
		}
	}

	public static func writeStdinSessionID(from argsJSON: String?) -> String? {
		guard let object = CodexJSONAccess.object(from: argsJSON) else { return nil }
		for key in ["session_id", "sessionId", "sessionID"] {
			if let string = CodexJSONAccess.string(object, key: key), !string.isEmpty {
				return string
			}
			if let number = object[key] as? NSNumber {
				return number.stringValue
			}
		}
		return nil
	}

	public static func writeStdinIsPoll(argsJSON: String?) -> Bool {
		guard let object = CodexJSONAccess.object(from: argsJSON) else { return false }
		if let chars = CodexJSONAccess.string(object, key: "chars") {
			return chars.isEmpty
		}
		return false
	}

	public static func writeStdinResultIndicatesRunning(
		resultJSON: String?,
		isError: Bool?
	) -> Bool {
		guard isError != true else { return false }
		guard let object = writeStdinResultObject(from: resultJSON) else { return false }
		if commandExecutionExitCode(from: object) != nil {
			return false
		}
		if let error = CodexJSONAccess.string(object, key: "error")?.trimmingCharacters(in: .whitespacesAndNewlines),
			!error.isEmpty {
			return false
		}
		if let status = CodexJSONAccess.string(object, key: "status")?
			.trimmingCharacters(in: .whitespacesAndNewlines)
			.lowercased() {
			if commandExecutionRunningStatusWords.contains(status) {
				return true
			}
			if commandExecutionTerminalStatusWords.contains(status) {
				return false
			}
		}
		return false
	}

	public static func writeStdinResultObject(from raw: String?) -> [String: Any]? {
		guard let object = CodexJSONAccess.object(from: raw) else { return nil }
		if object["Ok"] != nil || object["Err"] != nil {
			if let extracted = textFromMCPToolResult(object),
				let extractedObject = CodexJSONAccess.object(from: extracted) {
				return extractedObject
			}
		}
		return object
	}

	public static func commandExecutionProcessID(from raw: String?) -> String? {
		guard let object = CodexJSONAccess.object(from: raw) else { return nil }
		for key in ["processId", "process_id"] {
			if let value = CodexJSONAccess.string(object, key: key), !value.isEmpty {
				return value
			}
			if let number = object[key] as? NSNumber {
				return number.stringValue
			}
		}
		return nil
	}

	public static func canonicalCommandProcessIDs(for rawProcessID: String?) -> [String] {
		guard let rawProcessID = rawProcessID?.trimmingCharacters(in: .whitespacesAndNewlines),
			!rawProcessID.isEmpty else {
			return []
		}
		let lowercased = rawProcessID.lowercased()
		if lowercased.hasPrefix("session:") {
			let bare = String(rawProcessID.dropFirst("session:".count)).trimmingCharacters(in: .whitespacesAndNewlines)
			if bare.isEmpty {
				return [rawProcessID]
			}
			if bare == rawProcessID {
				return [rawProcessID]
			}
			return [rawProcessID, bare]
		}
		return [rawProcessID, "session:\(rawProcessID)"]
	}

	public static func commandExecutionCallID(from raw: String?) -> String? {
		guard let object = CodexJSONAccess.object(from: raw) else { return nil }
		for key in ["id", "callId", "call_id"] {
			if let value = CodexJSONAccess.string(object, key: key), !value.isEmpty {
				return value
			}
		}
		return nil
	}
}

public enum CommandExecutionOutputSanitizer {
	private static let escapeChar = "\u{001B}"
	private static let csiRegex = try! NSRegularExpression(
		pattern: #"(?:\x1B\[|\x9B)[0-?]*[ -/]*[@-~]"#,
		options: []
	)
	private static let oscRegex = try! NSRegularExpression(
		pattern: #"\x1B\][\s\S]*?(?:\x07|\x1B\\)"#,
		options: []
	)
	private static let dcsRegex = try! NSRegularExpression(
		pattern: #"\x1B[P^_X][\s\S]*?\x1B\\"#,
		options: []
	)
	private static let singleEscapeRegex = try! NSRegularExpression(
		pattern: #"\x1B[@-Z\\-_]"#,
		options: []
	)

	public static func sanitize(_ raw: String) -> String {
		guard !raw.isEmpty else { return raw }
		guard requiresSanitization(raw) else { return raw }
		var text = raw.replacingOccurrences(of: "\r\n", with: "\n")
		text = stripEscapeSequences(text)
		text = applyBackspaces(text)
		text = applyCarriageReturnOverwrite(text)
		text = stripUnwantedControlScalars(text)
		return text
	}

	private static func stripEscapeSequences(_ input: String) -> String {
		guard input.contains(escapeChar) || input.contains("\u{009B}") else { return input }
		let fullRange = NSRange(input.startIndex..<input.endIndex, in: input)
		var output = csiRegex.stringByReplacingMatches(in: input, options: [], range: fullRange, withTemplate: "")
		let rangeAfterCSI = NSRange(output.startIndex..<output.endIndex, in: output)
		output = oscRegex.stringByReplacingMatches(in: output, options: [], range: rangeAfterCSI, withTemplate: "")
		let rangeAfterOSC = NSRange(output.startIndex..<output.endIndex, in: output)
		output = dcsRegex.stringByReplacingMatches(in: output, options: [], range: rangeAfterOSC, withTemplate: "")
		let rangeAfterDCS = NSRange(output.startIndex..<output.endIndex, in: output)
		output = singleEscapeRegex.stringByReplacingMatches(in: output, options: [], range: rangeAfterDCS, withTemplate: "")
		return output
	}

	private static func requiresSanitization(_ input: String) -> Bool {
		for scalar in input.unicodeScalars {
			switch scalar.value {
			case 0x1B, 0x9B, 0x08, 0x0D:
				return true
			case 0x00...0x1F where scalar.value != 0x09 && scalar.value != 0x0A:
				return true
			default:
				continue
			}
		}
		return false
	}

	private static func applyBackspaces(_ input: String) -> String {
		guard input.contains("\u{0008}") else { return input }
		var output = ""
		output.reserveCapacity(input.count)
		for scalar in input.unicodeScalars {
			if scalar.value == 0x08 {
				if !output.isEmpty {
					output.removeLast()
				}
				continue
			}
			output.unicodeScalars.append(scalar)
		}
		return output
	}

	private static func applyCarriageReturnOverwrite(_ input: String) -> String {
		guard input.contains("\r") else { return input }
		let lines = input.split(separator: "\n", omittingEmptySubsequences: false)
		let rewritten = lines.map { line -> String in
			guard let segment = line.split(separator: "\r", omittingEmptySubsequences: false).last else { return "" }
			return String(segment)
		}
		return rewritten.joined(separator: "\n")
	}

	private static func stripUnwantedControlScalars(_ input: String) -> String {
		var output = ""
		output.reserveCapacity(input.count)
		for scalar in input.unicodeScalars {
			switch scalar.value {
			case 0x09, 0x0A:
				output.unicodeScalars.append(scalar)
			case 0x20...0x10FFFF:
				output.unicodeScalars.append(scalar)
			default:
				continue
			}
		}
		return output
	}
}
