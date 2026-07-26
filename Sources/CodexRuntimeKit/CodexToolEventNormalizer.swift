import Foundation
import Synchronization

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
public final class CodexToolEventNormalizer: Sendable {
	public struct FileChangeStreamState: Sendable {
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

	private struct CommandExecutionMirrorState: Sendable {
		let family: CommandExecutionEventFamily
		var lastSeenAt: Date
	}

	private static let commandExecutionMirrorStateTTL: TimeInterval = 30 * 60
	private static let maxCommandExecutionMirrorEntries = 512

	private let clock: @Sendable () -> Date
	/// Injected RepoPrompt tool-name knowledge; consumed by the parser
	/// tranche as tool-name normalization moves into this type.
	let toolNamePolicy: CodexToolNamePolicy
	/// Injected debug sink (the app's logCodexDebug). Takes an unevaluated
	/// producer so interpolation stays lazy when debug logging is disabled;
	/// call through the `debugLog(_:)` autoclosure convenience.
	let debugLogProducerSink: @Sendable (@escaping @Sendable () -> String) -> Void

	/// Sole owner of this type's mutable correlation state.
	///
	/// These four collections were plain unsynchronized properties on a class
	/// handed to the Codex controller, which shares it across its inbound pump
	/// tasks. Unsynchronized `Dictionary`/`Set` storage under concurrent
	/// mutation corrupts rather than merely racing — the same defect that
	/// produced the intermittent `CodexRPCRequestStore` SIGSEGV before
	/// 0.1.0-beta.2. The lock is never held across a call-out.
	private struct State: Sendable {
		var fileChangeStateByItemID: [String: FileChangeStreamState] = [:]
		var terminalFileChangeItemIDs: Set<String> = []
		var commandExecutionMirrorStateByItemID: [String: CommandExecutionMirrorState] = [:]
		var emittedToolEventDedupKeys: Set<String> = []
	}

	private let state = Mutex(State())

	public init(
		toolNamePolicy: CodexToolNamePolicy,
		clock: @escaping @Sendable () -> Date = { Date() },
		debugLog: @escaping @Sendable (@escaping @Sendable () -> String) -> Void = { _ in }
	) {
		self.toolNamePolicy = toolNamePolicy
		self.clock = clock
		self.debugLogProducerSink = debugLog
	}

	/// Lazy logging convenience: the message expression is wrapped, handed to
	/// the sink as a producer, and built only if the sink decides to log.
	func debugLog(_ message: @autoclosure @escaping @Sendable () -> String) {
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

	/// Was a `contains` test followed by a separate `insert`, so two emitters
	/// racing on one key could both believe they were first and emit the tool
	/// event twice. `insert(_:).inserted` makes it one locked operation.
	public func markToolEventEmitted(key: String) -> Bool {
		state.withLock { $0.emittedToolEventDedupKeys.insert(key).inserted }
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
		// Prune, test and record in ONE region. Split apart, two events for the
		// same itemID could both read no existing family and both be accepted,
		// defeating the mirror-family guard entirely.
		return state.withLock { state in
			Self.pruneCommandExecutionMirrorState(&state, now: now)
			if let existing = state.commandExecutionMirrorStateByItemID[trimmedItemID] {
				guard existing.family == family else {
					return false
				}
			}
			state.commandExecutionMirrorStateByItemID[trimmedItemID] = .init(
				family: family,
				lastSeenAt: now
			)
			return true
		}
	}

	/// Static so it can run inside an existing locked region without any risk
	/// of re-entering the (non-recursive) mutex.
	private static func pruneCommandExecutionMirrorState(_ state: inout State, now: Date) {
		let cutoff = now.addingTimeInterval(-Self.commandExecutionMirrorStateTTL)
		state.commandExecutionMirrorStateByItemID = state.commandExecutionMirrorStateByItemID.filter {
			$0.value.lastSeenAt >= cutoff
		}
		let overflow = state.commandExecutionMirrorStateByItemID.count - Self.maxCommandExecutionMirrorEntries
		guard overflow > 0 else { return }
		let oldestKeys = state.commandExecutionMirrorStateByItemID
			.sorted { lhs, rhs in
				lhs.value.lastSeenAt < rhs.value.lastSeenAt
			}
			.prefix(overflow)
			.map(\.key)
		for key in oldestKeys {
			state.commandExecutionMirrorStateByItemID.removeValue(forKey: key)
		}
	}

	// MARK: - File-change stream state

	public func fileChangeState(for itemID: String) -> FileChangeStreamState? {
		state.withLock { $0.fileChangeStateByItemID[itemID] }
	}

	public func isFileChangeTerminal(_ itemID: String) -> Bool {
		state.withLock { $0.terminalFileChangeItemIDs.contains(itemID) }
	}

	/// A restarted itemID clears any prior terminal marker so deltas are
	/// accepted again.
	public func fileChangeStreamStarted(_ state: FileChangeStreamState) {
		self.state.withLock {
			$0.terminalFileChangeItemIDs.remove(state.itemID)
			$0.fileChangeStateByItemID[state.itemID] = state
		}
	}

	/// Drops stream state and marks the itemID terminal so late output deltas
	/// are suppressed.
	public func fileChangeStreamCompleted(itemID: String) {
		state.withLock {
			$0.fileChangeStateByItemID.removeValue(forKey: itemID)
			$0.terminalFileChangeItemIDs.insert(itemID)
		}
	}

	public func updateFileChangeState(_ state: FileChangeStreamState) {
		self.state.withLock { $0.fileChangeStateByItemID[state.itemID] = state }
	}

	// MARK: - Lifecycle resets

	public func resetForTurnBoundary() {
		state.withLock { $0.emittedToolEventDedupKeys.removeAll(keepingCapacity: true) }
	}

	public func resetMirrorForBinding() {
		state.withLock { $0.commandExecutionMirrorStateByItemID.removeAll(keepingCapacity: true) }
	}

	public func resetForThreadRestore() {
		state.withLock {
			$0.fileChangeStateByItemID.removeAll(keepingCapacity: true)
			$0.terminalFileChangeItemIDs.removeAll(keepingCapacity: true)
			$0.commandExecutionMirrorStateByItemID.removeAll(keepingCapacity: true)
		}
	}

	public func resetAll() {
		state.withLock {
			$0.fileChangeStateByItemID.removeAll(keepingCapacity: false)
			$0.terminalFileChangeItemIDs.removeAll(keepingCapacity: false)
			$0.commandExecutionMirrorStateByItemID.removeAll(keepingCapacity: false)
			$0.emittedToolEventDedupKeys.removeAll(keepingCapacity: false)
		}
	}
}
