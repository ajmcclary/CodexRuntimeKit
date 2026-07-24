import Foundation

// Runtime compatibility vocabulary for the Codex app-server integration.
// Pure values + classification policy only: the app resolves the executable,
// runs `--version`, and issues the probe requests; everything here is
// deterministic and unit-testable. Item 3 of the Codex hardening program —
// observe and warn; feature gating (item 4) consumes this state later.

/// Parsed `codex-cli` semantic version. Accepts either the bare triple
/// ("0.144.6", optionally with a prerelease suffix) or the full `--version`
/// output ("codex-cli 0.144.6"). Malformed input parses to nil — callers
/// classify that as `.malformed`, never as a comparison result.
public struct CodexCliVersion: Equatable, Comparable, Sendable, CustomStringConvertible {
	public let major: Int
	public let minor: Int
	public let patch: Int
	public let prerelease: String?

	public init(major: Int, minor: Int, patch: Int, prerelease: String? = nil) {
		self.major = major
		self.minor = minor
		self.patch = patch
		self.prerelease = prerelease
	}

	public static func parse(_ raw: String) -> CodexCliVersion? {
		var candidate = raw.trimmingCharacters(in: .whitespacesAndNewlines)
		if let range = candidate.range(of: #"codex-cli\s+"#, options: .regularExpression) {
			candidate = String(candidate[range.upperBound...])
		}
		guard let match = candidate.range(
			of: #"^(\d+)\.(\d+)\.(\d+)(?:-([0-9A-Za-z.-]+))?$"#,
			options: .regularExpression
		), match == candidate.startIndex..<candidate.endIndex else {
			return nil
		}
		var triple = candidate
		var prerelease: String?
		if let dash = candidate.firstIndex(of: "-") {
			triple = String(candidate[..<dash])
			prerelease = String(candidate[candidate.index(after: dash)...])
		}
		let parts = triple.split(separator: ".").compactMap { Int($0) }
		guard parts.count == 3 else { return nil }
		return CodexCliVersion(major: parts[0], minor: parts[1], patch: parts[2], prerelease: prerelease)
	}

	public static func < (lhs: CodexCliVersion, rhs: CodexCliVersion) -> Bool {
		if lhs.major != rhs.major { return lhs.major < rhs.major }
		if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
		if lhs.patch != rhs.patch { return lhs.patch < rhs.patch }
		// A prerelease precedes its release at the same triple.
		switch (lhs.prerelease, rhs.prerelease) {
		case (nil, nil): return false
		case (.some, nil): return true
		case (nil, .some): return false
		case (.some(let left), .some(let right)): return left < right
		}
	}

	public var description: String {
		let base = "\(major).\(minor).\(patch)"
		return prerelease.map { "\(base)-\($0)" } ?? base
	}
}

/// Where a resolved CLI version stands relative to the vendored protocol
/// evidence. Deliberately NOT a supported range: the schema target, the
/// explicitly tested set, and the known-incompatible set are the only
/// positive claims; everything else is untested in one direction or the
/// other.
public enum CodexVersionAssessment: Equatable, Sendable {
	/// Exactly the release the vendored schemas were generated from.
	case schemaTarget
	/// A release the test suites have explicitly run against.
	case testedCompatible
	/// Older than the schema target and not in the tested set.
	case olderUntested
	/// Newer than the schema target and not in the tested set.
	case newerUntested
	/// Explicitly recorded as incompatible.
	case knownIncompatible(reason: String)
	/// `--version` output that did not parse as a codex-cli version.
	case malformed(raw: String)
}

public enum CodexCompatibilityPolicy {
	/// Versions the suites have explicitly run against, beyond the schema
	/// target itself. 0.144.1 is the installed CLI the live integration
	/// suites exercise.
	public static let explicitlyTestedVersions: Set<String> = ["0.144.1"]

	/// Version string → reason. Deliberately empty until a release is
	/// actually observed to be incompatible; never invent a floor.
	public static let knownIncompatibleVersions: [String: String] = [:]

	public static func assess(
		rawVersion: String,
		schemaTarget: String = CodexProtocolLockSnapshot.schemaTargetCliVersion,
		testedVersions: Set<String> = explicitlyTestedVersions,
		knownIncompatible: [String: String] = knownIncompatibleVersions
	) -> CodexVersionAssessment {
		guard let version = CodexCliVersion.parse(rawVersion) else {
			return .malformed(raw: rawVersion)
		}
		let canonical = version.description
		if let reason = knownIncompatible[canonical] {
			return .knownIncompatible(reason: reason)
		}
		guard let target = CodexCliVersion.parse(schemaTarget) else {
			// A malformed lock is a build defect; surface it as malformed
			// rather than guessing.
			return .malformed(raw: "schema target \(schemaTarget)")
		}
		if version == target {
			return .schemaTarget
		}
		if testedVersions.contains(canonical) {
			return .testedCompatible
		}
		return version < target ? .olderUntested : .newerUntested
	}
}

// MARK: - Capability probes

/// Protocol lane an endpoint is declared in at the pinned schema target
/// (mirrors the lanes in codex-used-surface.json).
public enum CodexProtocolLane: String, Equatable, Sendable {
	case stable
	case experimental
}

/// A diagnostics endpoint the compatibility probe queries. Lane-aware so
/// older or stable-only servers degrade to `.unsupported` instead of failing.
public struct CodexCapabilityEndpoint: Equatable, Sendable {
	public let method: String
	public let lane: CodexProtocolLane
	public let title: String

	public static let modelProviderCapabilities = CodexCapabilityEndpoint(
		method: "modelProvider/capabilities/read",
		lane: .stable,
		title: "Model-provider capabilities"
	)
	public static let experimentalFeatures = CodexCapabilityEndpoint(
		method: "experimentalFeature/list",
		lane: .stable,
		title: "Feature lifecycle"
	)
	public static let permissionProfiles = CodexCapabilityEndpoint(
		method: "permissionProfile/list",
		lane: .stable,
		title: "Permission profiles"
	)
	public static let all: [CodexCapabilityEndpoint] = [
		.modelProviderCapabilities,
		.experimentalFeatures,
		.permissionProfiles
	]
}

/// Outcome of probing one endpoint. Absence is a first-class, non-fatal
/// state distinct from transport and decoding failures.
public enum CodexCapabilityProbeOutcome: Equatable, Sendable {
	case supported(summary: String)
	/// The server does not implement the method (older/stable-only CLI).
	case unsupported
	case transportFailure(String)
	case decodeFailure(String)
	/// An RPC error other than method absence.
	case requestFailure(code: Int?, message: String)
	case notQueried
}

public struct CodexCapabilityProbeResult: Equatable, Sendable {
	public let endpoint: CodexCapabilityEndpoint
	public let outcome: CodexCapabilityProbeOutcome

	public init(endpoint: CodexCapabilityEndpoint, outcome: CodexCapabilityProbeOutcome) {
		self.endpoint = endpoint
		self.outcome = outcome
	}
}

public enum CodexCapabilityProbeClassifier {
	/// Whether an RPC error means "this server has no such method".
	///
	/// codex-cli rejects unknown methods with JSON-RPC -32600 and an
	/// "unknown variant `<method>`" message (verified empirically on
	/// 0.144.6); -32601 is the JSON-RPC standard method-not-found code and
	/// is accepted for forward compatibility.
	public static func isMethodAbsenceError(code: Int?, message: String) -> Bool {
		if code == -32601 {
			return true
		}
		return code == -32600 && message.contains("unknown variant")
	}

	/// Maps a failed probe request onto the outcome vocabulary. Absence is
	/// never conflated with transport or decoding failure.
	public static func outcome(for error: CodexClientError) -> CodexCapabilityProbeOutcome {
		switch error {
		case .rpcError(let code, let message):
			if isMethodAbsenceError(code: code, message: message) {
				return .unsupported
			}
			return .requestFailure(code: code, message: message)
		case .requestFailed(let message):
			if isMethodAbsenceError(code: nil, message: message) {
				return .unsupported
			}
			return .requestFailure(code: nil, message: message)
		case .invalidResponse, .jsonDecodeFailed:
			return .decodeFailure(String(describing: error))
		case .processNotRunning, .executableUnavailable,
			.transportWriteFailed, .transportReadSetupFailed:
			return .transportFailure(String(describing: error))
		case .experimentalRequirementNotAdmitted(_, let requirement):
			// A client-side fail-closed refusal, not a server verdict.
			return .requestFailure(code: nil, message: "not admitted: requires \(requirement)")
		}
	}
}

// MARK: - Known schema divergences

/// A verified, pinned divergence between what RepoPrompt sends/reads and
/// what the pinned schema declares. Mirrors the `*KnownMissingFromSchema` /
/// `*ExperimentalOnly` classifications in codex-used-surface.json;
/// CodexProtocolLockTests asserts the two stay identical.
public struct CodexProtocolKnownDivergence: Equatable, Sendable {
	public enum Kind: String, Equatable, Sendable {
		case fieldMissingFromSchema
		case fieldExperimentalOnly
		case methodExperimentalOnly
	}

	public let method: String
	public let fields: [String]
	public let kind: Kind

	public init(method: String, fields: [String], kind: Kind) {
		self.method = method
		self.fields = fields
		self.kind = kind
	}

	public var summary: String {
		switch kind {
		case .fieldMissingFromSchema:
			return "\(method): \(fields.joined(separator: ", ")) not declared by the pinned schema"
		case .fieldExperimentalOnly:
			return "\(method): \(fields.joined(separator: ", ")) declared only in the experimental lane"
		case .methodExperimentalOnly:
			return "\(method): declared only in the experimental lane"
		}
	}
}

public enum CodexProtocolKnownDivergences {
	public static let current: [CodexProtocolKnownDivergence] = [
		CodexProtocolKnownDivergence(method: "thread/start", fields: ["effort"], kind: .fieldMissingFromSchema),
		CodexProtocolKnownDivergence(method: "thread/resume", fields: ["effort"], kind: .fieldMissingFromSchema),
		CodexProtocolKnownDivergence(method: "thread/resume", fields: ["path"], kind: .fieldExperimentalOnly),
		CodexProtocolKnownDivergence(method: "thread/read", fields: ["model", "reasoningEffort"], kind: .fieldMissingFromSchema),
		CodexProtocolKnownDivergence(method: "thread/memoryMode/set", fields: [], kind: .methodExperimentalOnly)
	]
}

// MARK: - Snapshot

/// Everything the diagnostics surface knows about the resolved Codex
/// runtime. Values are already redaction-safe: paths, versions, mode labels,
/// and schema hashes only — never credentials, tokens, or environment
/// values.
public struct CodexRuntimeCompatibilitySnapshot: Equatable, Sendable {
	public enum AuthMode: Equatable, Sendable {
		/// RepoPrompt injects an API key into the child environment.
		case apiKeyInjected
		/// Codex's own credential store (ChatGPT or its API-key login).
		case codexManaged
		case unknown

		public var label: String {
			switch self {
			case .apiKeyInjected: return "API key (per-process injection)"
			case .codexManaged: return "Codex-managed (ChatGPT / CLI login)"
			case .unknown: return "Unknown"
			}
		}
	}

	public let executablePath: String?
	public let rawVersion: String?
	public let assessment: CodexVersionAssessment?
	public let schemaTargetVersion: String
	public let schemaSourceBinarySha256: String
	public let authMode: AuthMode
	public let probes: [CodexCapabilityProbeResult]
	public let knownDivergences: [CodexProtocolKnownDivergence]

	public init(
		executablePath: String?,
		rawVersion: String?,
		assessment: CodexVersionAssessment?,
		schemaTargetVersion: String = CodexProtocolLockSnapshot.schemaTargetCliVersion,
		schemaSourceBinarySha256: String = CodexProtocolLockSnapshot.sourceBinarySha256,
		authMode: AuthMode,
		probes: [CodexCapabilityProbeResult],
		knownDivergences: [CodexProtocolKnownDivergence] = CodexProtocolKnownDivergences.current
	) {
		self.executablePath = executablePath
		self.rawVersion = rawVersion
		self.assessment = assessment
		self.schemaTargetVersion = schemaTargetVersion
		self.schemaSourceBinarySha256 = schemaSourceBinarySha256
		self.authMode = authMode
		self.probes = probes
		self.knownDivergences = knownDivergences
	}

	/// Human-readable degradation reasons. Item 3 contract: newer untested
	/// warns, known-incompatible/below-target states are called out
	/// explicitly, probe failures explain themselves — nothing here changes
	/// behavior.
	public var warnings: [String] {
		var reasons: [String] = []
		switch assessment {
		case .none:
			reasons.append("Codex CLI version has not been checked.")
		case .schemaTarget, .testedCompatible:
			break
		case .olderUntested:
			reasons.append(
				"Codex CLI \(rawVersion ?? "?") is older than the pinned schema target \(schemaTargetVersion) and has not been tested; some endpoints may be missing."
			)
		case .newerUntested:
			reasons.append(
				"Codex CLI \(rawVersion ?? "?") is newer than the pinned schema target \(schemaTargetVersion) and has not been tested against this build."
			)
		case .knownIncompatible(let reason):
			reasons.append("Codex CLI \(rawVersion ?? "?") is known incompatible: \(reason)")
		case .malformed(let raw):
			reasons.append("Codex CLI version output was not recognized: \(raw)")
		}
		for probe in probes {
			switch probe.outcome {
			case .supported, .notQueried:
				break
			case .unsupported:
				reasons.append("\(probe.endpoint.title) endpoint (\(probe.endpoint.method)) is not implemented by this CLI.")
			case .transportFailure(let detail):
				reasons.append("\(probe.endpoint.title) probe failed at the transport layer: \(detail)")
			case .decodeFailure(let detail):
				reasons.append("\(probe.endpoint.title) probe returned an undecodable payload: \(detail)")
			case .requestFailure(let code, let message):
				reasons.append("\(probe.endpoint.title) probe was rejected (code \(code.map(String.init) ?? "none")): \(message)")
			}
		}
		return reasons
	}
}
