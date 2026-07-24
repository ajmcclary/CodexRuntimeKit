import XCTest
@testable import CodexRuntimeKit

final class CodexRuntimeCompatibilityTests: XCTestCase {

	// MARK: - Version parsing

	func testParsesBareTriple() {
		let version = CodexCliVersion.parse("0.144.6")
		XCTAssertEqual(version, CodexCliVersion(major: 0, minor: 144, patch: 6))
	}

	func testParsesFullVersionOutput() {
		let version = CodexCliVersion.parse("codex-cli 0.144.6\n")
		XCTAssertEqual(version, CodexCliVersion(major: 0, minor: 144, patch: 6))
	}

	func testParsesPrerelease() {
		let version = CodexCliVersion.parse("codex-cli 0.145.0-alpha.29")
		XCTAssertEqual(version, CodexCliVersion(major: 0, minor: 145, patch: 0, prerelease: "alpha.29"))
	}

	func testMalformedOutputsParseToNil() {
		for raw in ["", "codex-cli", "0.144", "banana", "zsh: command not found: codex", "0.144.6 extra"] {
			XCTAssertNil(CodexCliVersion.parse(raw), "expected nil for \(raw)")
		}
	}

	func testOrderingIncludingPrerelease() {
		let older = CodexCliVersion.parse("0.141.0")!
		let target = CodexCliVersion.parse("0.144.6")!
		let newerPre = CodexCliVersion.parse("0.145.0-alpha.29")!
		let newer = CodexCliVersion.parse("0.145.0")!
		XCTAssertLessThan(older, target)
		XCTAssertLessThan(target, newerPre)
		XCTAssertLessThan(newerPre, newer, "a prerelease precedes its release at the same triple")
	}

	// MARK: - Assessment

	func testAssessmentDistinguishesTargetTestedOlderNewer() {
		XCTAssertEqual(CodexCompatibilityPolicy.assess(rawVersion: "codex-cli 0.144.6"), .schemaTarget)
		XCTAssertEqual(CodexCompatibilityPolicy.assess(rawVersion: "codex-cli 0.144.1"), .testedCompatible)
		XCTAssertEqual(CodexCompatibilityPolicy.assess(rawVersion: "codex-cli 0.141.0"), .olderUntested)
		XCTAssertEqual(CodexCompatibilityPolicy.assess(rawVersion: "codex-cli 0.145.0-alpha.29"), .newerUntested)
	}

	func testAssessmentReportsMalformed() {
		guard case .malformed(let raw) = CodexCompatibilityPolicy.assess(rawVersion: "command not found") else {
			return XCTFail("Expected malformed assessment")
		}
		XCTAssertEqual(raw, "command not found")
	}

	func testAssessmentHonorsKnownIncompatibleOverTestedSet() {
		let assessment = CodexCompatibilityPolicy.assess(
			rawVersion: "codex-cli 0.144.1",
			knownIncompatible: ["0.144.1": "breaks turn/start framing"]
		)
		XCTAssertEqual(assessment, .knownIncompatible(reason: "breaks turn/start framing"))
	}

	func testKnownIncompatibleSetStartsEmpty() {
		XCTAssertTrue(
			CodexCompatibilityPolicy.knownIncompatibleVersions.isEmpty,
			"Never invent an incompatibility; entries require an observed failure"
		)
	}

	func testSchemaTargetComesFromGeneratedLockSnapshot() {
		XCTAssertEqual(
			CodexCompatibilityPolicy.assess(rawVersion: CodexProtocolLockSnapshot.schemaTargetCliVersion),
			.schemaTarget,
			"Default schema target must be the generated lock value, not a hand-copied constant"
		)
	}

	// MARK: - Method-absence classification

	func testStandardMethodNotFoundCodeIsAbsence() {
		XCTAssertTrue(CodexCapabilityProbeClassifier.isMethodAbsenceError(code: -32601, message: "method not found"))
	}

	func testCodexUnknownVariantRejectionIsAbsence() {
		// Real codex-cli 0.144.6 shape for an unknown method.
		XCTAssertTrue(CodexCapabilityProbeClassifier.isMethodAbsenceError(
			code: -32600,
			message: "Invalid request: unknown variant `definitely/not/a/method`, expected one of `initialize`, `thread/start`"
		))
	}

	func testOtherInvalidRequestErrorsAreNotAbsence() {
		XCTAssertFalse(CodexCapabilityProbeClassifier.isMethodAbsenceError(code: -32600, message: "missing field `threadId`"))
		XCTAssertFalse(CodexCapabilityProbeClassifier.isMethodAbsenceError(code: -32603, message: "internal error"))
		XCTAssertFalse(CodexCapabilityProbeClassifier.isMethodAbsenceError(code: nil, message: "unknown variant"))
	}

	// MARK: - Error → outcome mapping

	func testAbsenceRpcErrorMapsToUnsupported() {
		let outcome = CodexCapabilityProbeClassifier.outcome(
			for: .rpcError(code: -32600, message: "Invalid request: unknown variant `permissionProfile/list`")
		)
		XCTAssertEqual(outcome, .unsupported)
	}

	func testNonAbsenceRpcErrorMapsToRequestFailure() {
		let outcome = CodexCapabilityProbeClassifier.outcome(for: .rpcError(code: -32603, message: "boom"))
		XCTAssertEqual(outcome, .requestFailure(code: -32603, message: "boom"))
	}

	func testDecodeErrorsMapToDecodeFailure() {
		for error in [CodexClientError.invalidResponse, .jsonDecodeFailed] {
			guard case .decodeFailure = CodexCapabilityProbeClassifier.outcome(for: error) else {
				return XCTFail("Expected decodeFailure for \(error)")
			}
		}
	}

	func testTransportErrorsMapToTransportFailure() {
		let errors: [CodexClientError] = [
			.processNotRunning,
			.executableUnavailable("gone"),
			.transportWriteFailed(message: "pipe", errno: 32),
			.transportReadSetupFailed(message: "fd", errno: 9)
		]
		for error in errors {
			guard case .transportFailure = CodexCapabilityProbeClassifier.outcome(for: error) else {
				return XCTFail("Expected transportFailure for \(error)")
			}
		}
	}

	// MARK: - Snapshot warnings

	private func snapshot(
		rawVersion: String?,
		probes: [CodexCapabilityProbeResult] = []
	) -> CodexRuntimeCompatibilitySnapshot {
		CodexRuntimeCompatibilitySnapshot(
			executablePath: "/usr/local/bin/codex",
			rawVersion: rawVersion,
			assessment: rawVersion.map { CodexCompatibilityPolicy.assess(rawVersion: $0) },
			authMode: .codexManaged,
			probes: probes
		)
	}

	func testTargetAndTestedVersionsProduceNoVersionWarnings() {
		XCTAssertTrue(snapshot(rawVersion: "codex-cli 0.144.6").warnings.isEmpty)
		XCTAssertTrue(snapshot(rawVersion: "codex-cli 0.144.1").warnings.isEmpty)
	}

	func testNewerUntestedWarnsWithoutFailing() {
		let warnings = snapshot(rawVersion: "codex-cli 0.145.0-alpha.29").warnings
		XCTAssertEqual(warnings.count, 1)
		XCTAssertTrue(warnings[0].contains("newer than the pinned schema target"))
	}

	func testOlderUntestedAndMalformedWarn() {
		XCTAssertTrue(snapshot(rawVersion: "codex-cli 0.141.0").warnings[0].contains("older than the pinned schema target"))
		XCTAssertTrue(snapshot(rawVersion: "garbage").warnings[0].contains("not recognized"))
	}

	func testProbeDegradationsExplainThemselves() {
		let probes = [
			CodexCapabilityProbeResult(endpoint: .modelProviderCapabilities, outcome: .unsupported),
			CodexCapabilityProbeResult(endpoint: .experimentalFeatures, outcome: .transportFailure("EPIPE")),
			CodexCapabilityProbeResult(endpoint: .permissionProfiles, outcome: .supported(summary: "ok"))
		]
		let warnings = snapshot(rawVersion: "codex-cli 0.144.6", probes: probes).warnings
		XCTAssertEqual(warnings.count, 2)
		XCTAssertTrue(warnings[0].contains("not implemented"))
		XCTAssertTrue(warnings[1].contains("transport layer"))
	}
}
