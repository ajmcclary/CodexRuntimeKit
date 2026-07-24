import Foundation

// Named experimental-feature admission for the Codex app-server transport.
// Item 4 of the Codex hardening program: replaces the blanket
// `"experimentalApi": true` initialize capability with per-transport,
// immutable, named requirements. Stable initialization omits `experimentalApi`
// entirely; each requirement maps to the exact protocol surface that needs
// it (the surface pinned experimental-only by codex-used-surface.json /
// CodexProtocolKnownDivergences).

/// A named reason to opt a transport into the experimental API. Raw values
/// are stable identifiers; an unknown raw value decodes to nil and is
/// therefore never admitted (fail closed).
public enum CodexExperimentalRequirement: String, CaseIterable, Sendable, Hashable, Comparable {
	/// Emitting `thread/resume.path` — the rollout-path resume used only by
	/// legacy persisted sessions that have no thread ID. `path` is declared
	/// only in the experimental schema lane at the pinned target.
	case legacyThreadResumePath
	/// Sending `thread/memoryMode/set` — an experimental-lane-only method.
	case memoryMode

	public static func < (lhs: Self, rhs: Self) -> Bool {
		lhs.rawValue < rhs.rawValue
	}
}

/// Maps requests onto the requirement they need. This is the fail-closed
/// gate's knowledge: an experimental-lane request with no admitted
/// requirement must never cross the wire.
public enum CodexExperimentalSurface {
	/// Requirement needed for a method regardless of params.
	public static func requirement(forMethod method: String) -> CodexExperimentalRequirement? {
		method == "thread/memoryMode/set" ? .memoryMode : nil
	}

	/// Requirement needed for a method with the given top-level param keys
	/// (covers experimental-only fields on otherwise-stable methods).
	public static func requirement(forMethod method: String, paramKeys: Set<String>) -> CodexExperimentalRequirement? {
		if let methodRequirement = requirement(forMethod: method) {
			return methodRequirement
		}
		if method == "thread/resume", paramKeys.contains("path") {
			return .legacyThreadResumePath
		}
		return nil
	}
}

/// The admission decision frozen for one transport generation. Computed from
/// the client configuration BEFORE the process is spawned and the connection
/// initialized; never mutated afterwards — changing requirements restarts
/// the transport so admission always matches policy.
public struct CodexExperimentalAdmission: Equatable, Sendable {
	public let requirements: Set<CodexExperimentalRequirement>
	/// Why these requirements were requested (diagnostics only).
	public let reason: String

	public init(requirements: Set<CodexExperimentalRequirement>, reason: String) {
		self.requirements = requirements
		self.reason = reason
	}

	public var isStableOnly: Bool { requirements.isEmpty }

	public static let stableOnly = CodexExperimentalAdmission(
		requirements: [],
		reason: "stable-only: no experimental requirements"
	)

	public func admits(_ requirement: CodexExperimentalRequirement) -> Bool {
		requirements.contains(requirement)
	}
}

/// Diagnostics record: what one transport generation was admitted with.
public struct CodexExperimentalAdmissionRecord: Equatable, Sendable {
	public let transportGeneration: UInt64
	public let requirements: Set<CodexExperimentalRequirement>
	public let reason: String

	public init(transportGeneration: UInt64, requirements: Set<CodexExperimentalRequirement>, reason: String) {
		self.transportGeneration = transportGeneration
		self.requirements = requirements
		self.reason = reason
	}

	public var summary: String {
		let names = requirements.sorted().map(\.rawValue).joined(separator: ", ")
		return "generation \(transportGeneration): \(requirements.isEmpty ? "stable-only" : names) — \(reason)"
	}
}
