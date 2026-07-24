import Foundation

/// The host application's MCP tool-name knowledge the tool-event parsers
/// need, injected so CodexRuntimeCore stays free of both the app's helper
/// types and its product vocabulary. RepoPrompt specifics live solely in the
/// app-side adapter (MCPIntegrationHelperToolNamePolicy).
public protocol CodexToolNamePolicy: Sendable {
	/// The MCP server name whose tools the host application treats as its own.
	var mcpServerName: String { get }
	/// Whether the raw tool name already carries an explicit server prefix.
	func hasExplicitServerPrefix(_ rawName: String) -> Bool
	/// Whether a server identifier from the wire refers to the host's server.
	func matchesServerIdentifier(_ rawValue: String?) -> Bool
	/// Canonicalizes a raw tool name for the host's server.
	func normalizeToolName(_ rawName: String) -> String
}


/// Sole owner of the Codex tool-event correlation state that previously lived
/// as four collections on CodexNativeSessionController (2026-07-17):
///
/// - file-change stream state (`fileChangeStateByItemID`)
/// - terminal file-item IDs (`terminalFileChangeItemIDs`)
/// - command-family mirror state (`commandExecutionMirrorStateByItemID`)
/// - emitted-event deduplication (`emittedToolEventDedupKeys`)
///
/// Synchronous and caller-isolated: the controller owns the instance and calls
/// it from its own isolation; nothing here suspends. The clock is injected so
/// mirror-state TTL pruning is testable. Reset operations are explicit so the
/// lifecycle semantics stay visible at call sites:
///
/// - `resetForTurnBoundary` — turn started/completed clears dedup keys only.
/// - `resetMirrorForBinding` — binding begin/cancel clears mirror state only.
/// - `resetForThreadRestore` — snapshot restore clears both stream-state
///   collections and mirror state, keeping capacity; dedup keys survive.
/// - `resetAll` — shutdown; releases everything.
///
/// The full tool-event parsing surface lives on this type (see the Parsing
/// and Payloads extensions); AgentChatItem projection, persisted-rollout
/// reconciliation, and transcript concerns stay app-side.
public final class CodexToolEventNormalizer {
	public struct FileChangeStreamState {
		public let itemID: String
		public let invocationID: UUID?
		public var argsJSON: String?
		public var latestResultJSON: String?
		public var accumulatedOutput: String
		public var status: String

		public init(
			itemID: String,
			invocationID: UUID?,
			argsJSON: String?,
			latestResultJSON: String?,
			accumulatedOutput: String,
			status: String
		) {
			self.itemID = itemID
			self.invocationID = invocationID
			self.argsJSON = argsJSON
			self.latestResultJSON = latestResultJSON
			self.accumulatedOutput = accumulatedOutput
			self.status = status
		}
	}

	public enum CommandExecutionEventFamily: Sendable {
		case raw
		case normalized
	}

	private struct CommandExecutionMirrorState {
		let family: CommandExecutionEventFamily
		var lastSeenAt: Date
	}

	private static let commandExecutionMirrorStateTTL: TimeInterval = 30 * 60
	private static let maxCommandExecutionMirrorEntries = 512

	private let clock: () -> Date
	/// Injected RepoPrompt tool-name knowledge; consumed by the parser
	/// tranche as tool-name normalization moves into this type.
	let toolNamePolicy: CodexToolNamePolicy
	/// Injected debug sink (the app's logCodexDebug). Takes an unevaluated
	/// producer so interpolation stays lazy when debug logging is disabled;
	/// call through the `debugLog(_:)` autoclosure convenience.
	let debugLogProducerSink: (() -> String) -> Void

	private var fileChangeStateByItemID: [String: FileChangeStreamState] = [:]
	private var terminalFileChangeItemIDs: Set<String> = []
	private var commandExecutionMirrorStateByItemID: [String: CommandExecutionMirrorState] = [:]
	private var emittedToolEventDedupKeys: Set<String> = []

	public init(
		toolNamePolicy: CodexToolNamePolicy,
		clock: @escaping () -> Date = { Date() },
		debugLog: @escaping (() -> String) -> Void = { _ in }
	) {
		self.toolNamePolicy = toolNamePolicy
		self.clock = clock
		self.debugLogProducerSink = debugLog
	}

	/// Lazy logging convenience: the message expression is wrapped, handed to
	/// the sink as a producer, and built only if the sink decides to log.
	func debugLog(_ message: @autoclosure @escaping () -> String) {
		debugLogProducerSink(message)
	}

	// MARK: - Emitted-event deduplication

	public func toolDedupKey(
		itemID: String?,
		toolName: String,
		argsJSON: String?,
		resultJSON: String?
	) -> String {
		if let itemID = itemID?.trimmingCharacters(in: .whitespacesAndNewlines), !itemID.isEmpty {
			return itemID
		}
		let argsPart = argsJSON ?? ""
		let resultPart = resultJSON ?? ""
		return "\(toolName)|\(argsPart)|\(resultPart)"
	}

	public func markToolEventEmitted(key: String) -> Bool {
		if emittedToolEventDedupKeys.contains(key) {
			return false
		}
		emittedToolEventDedupKeys.insert(key)
		return true
	}

	// MARK: - Command-family mirror acceptance

	public func shouldAcceptCommandExecutionEvent(
		itemID: String?,
		family: CommandExecutionEventFamily,
		now overrideNow: Date? = nil
	) -> Bool {
		guard let trimmedItemID = itemID?.trimmingCharacters(in: .whitespacesAndNewlines),
			!trimmedItemID.isEmpty else {
			return true
		}
		let now = overrideNow ?? clock()
		pruneCommandExecutionMirrorState(now: now)
		if let existing = commandExecutionMirrorStateByItemID[trimmedItemID] {
			guard existing.family == family else {
				return false
			}
		}
		commandExecutionMirrorStateByItemID[trimmedItemID] = .init(
			family: family,
			lastSeenAt: now
		)
		return true
	}

	private func pruneCommandExecutionMirrorState(now: Date) {
		let cutoff = now.addingTimeInterval(-Self.commandExecutionMirrorStateTTL)
		commandExecutionMirrorStateByItemID = commandExecutionMirrorStateByItemID.filter {
			$0.value.lastSeenAt >= cutoff
		}
		let overflow = commandExecutionMirrorStateByItemID.count - Self.maxCommandExecutionMirrorEntries
		guard overflow > 0 else { return }
		let oldestKeys = commandExecutionMirrorStateByItemID
			.sorted { lhs, rhs in
				lhs.value.lastSeenAt < rhs.value.lastSeenAt
			}
			.prefix(overflow)
			.map(\.key)
		for key in oldestKeys {
			commandExecutionMirrorStateByItemID.removeValue(forKey: key)
		}
	}

	// MARK: - File-change stream state

	public func fileChangeState(for itemID: String) -> FileChangeStreamState? {
		fileChangeStateByItemID[itemID]
	}

	public func isFileChangeTerminal(_ itemID: String) -> Bool {
		terminalFileChangeItemIDs.contains(itemID)
	}

	/// A restarted itemID clears any prior terminal marker so deltas are
	/// accepted again.
	public func fileChangeStreamStarted(_ state: FileChangeStreamState) {
		terminalFileChangeItemIDs.remove(state.itemID)
		fileChangeStateByItemID[state.itemID] = state
	}

	/// Drops stream state and marks the itemID terminal so late output deltas
	/// are suppressed.
	public func fileChangeStreamCompleted(itemID: String) {
		fileChangeStateByItemID.removeValue(forKey: itemID)
		terminalFileChangeItemIDs.insert(itemID)
	}

	public func updateFileChangeState(_ state: FileChangeStreamState) {
		fileChangeStateByItemID[state.itemID] = state
	}

	// MARK: - Lifecycle resets

	public func resetForTurnBoundary() {
		emittedToolEventDedupKeys.removeAll(keepingCapacity: true)
	}

	public func resetMirrorForBinding() {
		commandExecutionMirrorStateByItemID.removeAll(keepingCapacity: true)
	}

	public func resetForThreadRestore() {
		fileChangeStateByItemID.removeAll(keepingCapacity: true)
		terminalFileChangeItemIDs.removeAll(keepingCapacity: true)
		commandExecutionMirrorStateByItemID.removeAll(keepingCapacity: true)
	}

	public func resetAll() {
		fileChangeStateByItemID.removeAll(keepingCapacity: false)
		terminalFileChangeItemIDs.removeAll(keepingCapacity: false)
		commandExecutionMirrorStateByItemID.removeAll(keepingCapacity: false)
		emittedToolEventDedupKeys.removeAll(keepingCapacity: false)
	}
}
