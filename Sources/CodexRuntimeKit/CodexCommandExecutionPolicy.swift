import AgentRuntimeKit
import Foundation

/// Pure command-execution projection policy, moved verbatim from
/// `CodexAgentModeCoordinator` (command-execution phase, 2026-07-18):
/// external tool-name normalization, command/process-ID extraction from
/// args JSON, execution-key derivation, running-output merging and capping,
/// running-update coalescing vocabulary, and the terminal-status JSON
/// transformations used when a running command is finalized.
///
/// NOTE: `withCommandExecutionTerminalStatus` deliberately differs from
/// `CodexToolEventNormalizer.withCommandExecutionTerminalCompletionStatus` —
/// this variant synthesizes `exitCode` 0/1 from the terminal status word and
/// seeds non-JSON raw payloads into `aggregatedOutput`. Do not converge the
/// two without a conscious behavior decision.
public enum CodexCommandExecutionPolicy {

	// MARK: - Tool-name normalization

	public static func normalizedExternalToolName(_ raw: String?) -> String? {
		guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
		let lowered = raw.lowercased()
		let suffix = lowered.split(separator: ".").last.map(String.init) ?? lowered
		switch suffix {
		case "local_shell", "shell", "unified_exec", "exec_command", "run_shell_command":
			return "bash"
		case "web_search", "web_search_request", "google_web_search", "search_web":
			return "search"
		default:
			return suffix
		}
	}

	// MARK: - Command / process-ID extraction

	public static func initialRunningCommandExecutionJSON(argsJSON: String?) -> String {
		var payload: [String: Any] = [
			"type": "commandExecution",
			"status": "running"
		]
		if let command = extractCommandFromArgsJSON(argsJSON) {
			payload["command"] = command
		}
		if let processID = extractProcessIDFromArgsJSON(argsJSON) {
			payload["processId"] = processID
		}
		if let data = try? JSONSerialization.data(withJSONObject: payload, options: []),
			let json = String(data: data, encoding: .utf8) {
			return json
		}
		return #"{"type":"commandExecution","status":"running"}"#
	}

	public static func extractCommandFromArgsJSON(_ argsJSON: String?) -> String? {
		guard let argsJSON = argsJSON?.trimmingCharacters(in: .whitespacesAndNewlines), !argsJSON.isEmpty else {
			return nil
		}
		if let data = argsJSON.data(using: .utf8),
			let value = try? JSONSerialization.jsonObject(with: data, options: []),
			let command = extractCommandValue(from: value) {
			return command
		}
		return argsJSON
	}

	private static func extractCommandValue(from value: Any) -> String? {
		if let object = value as? [String: Any] {
			for key in ["command", "cmd", "input", "text", "value", "argv", "args"] {
				if let command = extractCommandValue(from: object[key] as Any) {
					return command
				}
			}
			if let invocation = object["invocation"],
				let command = extractCommandValue(from: invocation) {
				return command
			}
			if let arguments = object["arguments"],
				let command = extractCommandValue(from: arguments) {
				return command
			}
			for nested in object.values {
				if let command = extractCommandValue(from: nested) {
					return command
				}
			}
			return nil
		}
		if let array = value as? [Any] {
			let parts = array
				.compactMap { element -> String? in
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
				if let command = extractCommandValue(from: nested) {
					return command
				}
			}
			return nil
		}
		if let string = value as? String {
			let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
			guard !trimmed.isEmpty else { return nil }
			if (trimmed.hasPrefix("{") || trimmed.hasPrefix("[") || trimmed.hasPrefix("\"")),
				let data = trimmed.data(using: .utf8),
				let nested = try? JSONSerialization.jsonObject(with: data, options: []),
				let command = extractCommandValue(from: nested) {
				return command
			}
			if let unquoted = unquotedCommandText(trimmed) {
				return unquoted
			}
			return trimmed
		}
		if let number = value as? NSNumber {
			let trimmed = number.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
			return trimmed.isEmpty ? nil : trimmed
		}
		return nil
	}

	private static func unquotedCommandText(_ raw: String) -> String? {
		guard raw.count >= 2 else { return nil }
		guard let first = raw.first, let last = raw.last, first == last, first == "\"" || first == "'" else {
			return nil
		}
		let inner = String(raw.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
		return inner.isEmpty ? nil : inner
	}

	public static func extractProcessIDFromArgsJSON(_ argsJSON: String?) -> String? {
		guard let argsJSON = argsJSON?.trimmingCharacters(in: .whitespacesAndNewlines), !argsJSON.isEmpty else {
			return nil
		}
		guard let data = argsJSON.data(using: .utf8),
			let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
			return nil
		}
		for key in ["processId", "process_id"] {
			if let value = object[key] as? String {
				let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
				if !trimmed.isEmpty { return trimmed }
			}
			if let value = object[key] as? NSNumber {
				let text = value.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
				if !text.isEmpty { return text }
			}
		}
		return nil
	}

	// MARK: - Execution keys and process-ID matching

	public static func bashExecutionKey(
		invocationID: UUID?,
		fallbackSignature: String?,
		processID: String? = nil
	) -> String? {
		if let invocationID {
			return "invocation:\(invocationID.uuidString)"
		}
		if let fallbackSignature = fallbackSignature?.trimmingCharacters(in: .whitespacesAndNewlines), !fallbackSignature.isEmpty {
			return "signature:\(fallbackSignature)"
		}
		if let processID = processID?.trimmingCharacters(in: .whitespacesAndNewlines), !processID.isEmpty {
			return "process:\(processID)"
		}
		return nil
	}

	public static func canonicalProcessIDSet(_ raw: String?) -> Set<String> {
		guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
			return []
		}
		var values: Set<String> = [raw]
		if raw.hasPrefix("session:") {
			let stripped = String(raw.dropFirst("session:".count)).trimmingCharacters(in: .whitespacesAndNewlines)
			if !stripped.isEmpty {
				values.insert(stripped)
			}
		} else {
			values.insert("session:\(raw)")
		}
		return values
	}

	public static func processIDsMatch(_ lhs: String?, _ rhs: String?) -> Bool {
		let lhsSet = canonicalProcessIDSet(lhs)
		guard !lhsSet.isEmpty else { return false }
		let rhsSet = canonicalProcessIDSet(rhs)
		guard !rhsSet.isEmpty else { return false }
		return !lhsSet.isDisjoint(with: rhsSet)
	}

	/// Whether a raw process-id string denotes a real, positive POSIX PID.
	///
	/// Neutral policy consumed by both `CodexBashLivenessCoordinator` (liveness
	/// probing) and `CodexCommandExecutionProjectionCoordinator` (terminal→running
	/// revival gating) so neither coordinator has to reference the other. A
	/// session-scoped pseudo-id (e.g. `session:27588`) or any non-numeric /
	/// non-positive value returns false — only a genuine OS PID can be probed for
	/// liveness or used to prove a terminal launch is still alive.
	public static func isCandidatePOSIXProcessID(_ processID: String) -> Bool {
		guard let pidValue = Int32(processID), pidValue > 0 else {
			return false
		}
		return true
	}

	// MARK: - Running-output merge and cap

	public static let maxMergedCommandRunningOutputCharacters: Int = 24_000

	public static func mergeCommandRunningOutput(
		existing: String?,
		incoming: String?
	) -> String? {
		let existingValue = (existing?.isEmpty == false) ? existing : nil
		let incomingValue = (incoming?.isEmpty == false) ? incoming : nil
		switch (existingValue, incomingValue) {
		case (nil, nil):
			return nil
		case (let value?, nil), (nil, let value?):
			return capMergedCommandRunningOutput(value)
		case (let existingValue?, let incomingValue?):
			let existingTail = capMergedCommandRunningOutput(existingValue)
			let incomingTail = capMergedCommandRunningOutput(incomingValue)
			let merged = existingTail + incomingTail
			return capMergedCommandRunningOutput(merged)
		}
	}

	public static func capMergedCommandRunningOutput(_ raw: String) -> String {
		let maxCharacters = maxMergedCommandRunningOutputCharacters
		guard raw.count > maxCharacters else { return raw }
		return String(raw.suffix(maxCharacters))
	}

	// MARK: - Running-update coalescing vocabulary

	public static func commandRunningUpdateKey(_ update: CodexCommandExecutionRunningUpdate) -> String {
		if let processID = update.processID, !processID.isEmpty {
			return "process:\(processID)"
		}
		if let invocationID = update.invocationID {
			return "invocation:\(invocationID.uuidString)"
		}
		return "unknown"
	}

	public static func mergeCommandRunningUpdates(
		_ existing: CodexCommandExecutionRunningUpdate,
		with incoming: CodexCommandExecutionRunningUpdate
	) -> CodexCommandExecutionRunningUpdate {
		let invocationID = incoming.invocationID ?? existing.invocationID
		let processID = incoming.processID ?? existing.processID
		let appendedOutput = mergeCommandRunningOutput(
			existing: existing.appendedOutput,
			incoming: incoming.appendedOutput
		)
		return .init(
			invocationID: invocationID,
			processID: processID,
			appendedOutput: appendedOutput,
			sealsAssistantBoundary: existing.sealsAssistantBoundary || incoming.sealsAssistantBoundary
		)
	}

	public struct Coalescing: Sendable, Equatable {
		public let statusDelayNanos: UInt64
		public let liveOutputDelayNanos: UInt64

		public static let `default` = Coalescing(
			statusDelayNanos: 75_000_000,
			liveOutputDelayNanos: 225_000_000
		)

		public init(statusDelayNanos: UInt64, liveOutputDelayNanos: UInt64) {
			self.statusDelayNanos = statusDelayNanos
			self.liveOutputDelayNanos = liveOutputDelayNanos
		}

		public func delayNanos(for update: CodexCommandExecutionRunningUpdate) -> UInt64 {
			if update.sealsAssistantBoundary {
				return statusDelayNanos
			}
			let hasOutput = update.appendedOutput?.isEmpty == false
			return hasOutput ? liveOutputDelayNanos : statusDelayNanos
		}
	}

	// MARK: - Terminal-status transformations

	public static func commandExecutionTerminalResultJSONByMergingLateOutput(
		raw: String?,
		appendedOutput: String?
	) -> String? {
		guard let incomingOutput = appendedOutput,
			!incomingOutput.isEmpty,
			let raw,
			let data = raw.data(using: .utf8),
			var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
		else { return nil }
		let existingOutput = commandExecutionOutputText(from: object)
		guard let mergedOutput = mergeCommandRunningOutput(existing: existingOutput, incoming: incomingOutput),
			mergedOutput != existingOutput
		else { return nil }
		object["aggregatedOutput"] = mergedOutput
		object.removeValue(forKey: "aggregated_output")
		guard JSONSerialization.isValidJSONObject(object),
			let encoded = try? JSONSerialization.data(withJSONObject: object, options: []),
			let json = String(data: encoded, encoding: .utf8)
		else { return nil }
		return json
	}

	/// Rebuilds a terminal command-execution payload as a *running* one, used when a
	/// fresh running signal proves a launch that briefly reported terminal is actually
	/// still alive (e.g. a long-running `npm start`). Drops the terminal exit code and
	/// any sanitized-summary marker, forces `status: running`, ensures the process id,
	/// and merges any appended output.
	public static func commandExecutionRunningResultJSONByRevivingTerminalLaunch(
		raw: String?,
		appendedOutput: String?,
		processID: String?
	) -> String {
		var object: [String: Any] = [:]
		if let raw,
			let data = raw.data(using: .utf8),
			let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
			object = json
		}
		object["type"] = "commandExecution"
		object["status"] = "running"
		object.removeValue(forKey: "exitCode")
		object.removeValue(forKey: "exit_code")
		object.removeValue(forKey: "code")
		object.removeValue(forKey: "summary_only")
		object.removeValue(forKey: "summaryOnly")
		if let processID = processID?.trimmingCharacters(in: .whitespacesAndNewlines),
			!processID.isEmpty {
			object["processId"] = processID
			object.removeValue(forKey: "process_id")
		}
		let existingOutput = commandExecutionOutputText(from: object)
		if let merged = mergeCommandRunningOutput(existing: existingOutput, incoming: appendedOutput) {
			object["aggregatedOutput"] = merged
			object.removeValue(forKey: "aggregated_output")
		}
		guard JSONSerialization.isValidJSONObject(object),
			let data = try? JSONSerialization.data(withJSONObject: object, options: []),
			let json = String(data: data, encoding: .utf8)
		else {
			return #"{"type":"commandExecution","status":"running"}"#
		}
		return json
	}

	private static func commandExecutionOutputText(from object: [String: Any]) -> String? {
		for key in [
			"aggregatedOutput", "aggregated_output",
			"formattedOutput", "formatted_output",
			"recentOutput", "recent_output",
			"combinedOutput", "combined_output",
			"output", "stdout", "stderr", "text", "message", "content", "result", "log", "logs"
		] {
			if let value = object[key] as? String,
				!value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
				return value
			}
		}
		return nil
	}

	public static func withCommandExecutionTerminalStatus(raw: String?, status: String) -> String {
		let trimmedRaw = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
		var object: [String: Any] = [:]
		if let raw,
			let data = raw.data(using: .utf8),
			let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
			object = json
		} else if !trimmedRaw.isEmpty {
			object["aggregatedOutput"] = trimmedRaw
		}

		if (object["type"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
			object["type"] = "commandExecution"
		}
		object["status"] = status

		if object["processId"] == nil, let processID = object["process_id"] {
			object["processId"] = processID
		}
		object.removeValue(forKey: "process_id")

		let hasExitCode =
			object["exitCode"] != nil
			|| object["exit_code"] != nil
			|| object["code"] != nil
		if !hasExitCode {
			switch status {
			case "completed":
				object["exitCode"] = 0
			case "failed", "cancelled", "canceled":
				object["exitCode"] = 1
			default:
				break
			}
		}

		guard JSONSerialization.isValidJSONObject(object),
			let data = try? JSONSerialization.data(withJSONObject: object, options: []),
			let json = String(data: data, encoding: .utf8)
		else {
			return #"{"type":"commandExecution","status":"\#(status)"}"#
		}
		return json
	}

	// MARK: - Turn-status vocabulary

	public static func terminalCommandStatusWord(for turnStatus: CodexTurnStatus) -> String {
		switch turnStatus {
		case .completed:
			return "completed"
		case .interrupted:
			return "cancelled"
		case .failed:
			return "failed"
		}
	}

	public static func fallbackToolResultJSON(for turnStatus: CodexTurnStatus) -> String {
		let status: String = (turnStatus == .failed) ? "failed" : "unknown"
		let payload: [String: Any] = [
			"status": status,
			"note": "No tool result payload was received before the turn ended."
		]
		if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted]),
			let json = String(data: data, encoding: .utf8) {
			return json
		}
		return "{\"status\":\"\(status)\"}"
	}

	public static func agentSessionRunState(for turnStatus: CodexTurnStatus) -> AgentSessionRunState {
		switch turnStatus {
		case .completed:
			return .completed
		case .interrupted:
			return .cancelled
		case .failed:
			return .failed
		}
	}

	public static func codexTurnStatus(forTerminalState terminalState: AgentSessionRunState) -> CodexTurnStatus? {
		switch terminalState {
		case .completed:
			return .completed
		case .cancelled:
			return .interrupted
		case .failed:
			return .failed
		case .idle, .running, .waitingForUser, .waitingForQuestion, .waitingForApproval:
			return nil
		}
	}
}
